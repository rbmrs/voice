#!/usr/bin/env python3
"""Linux terminal MVP for the Voice dictation pipeline."""

from __future__ import annotations

import argparse
import base64
import ctypes
import ctypes.util
import curses
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import textwrap
import time
import urllib.error
import urllib.request
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Sequence, TypeVar


SAMPLE_RATE = 16_000
CHANNELS = 1
LLAMA_TIMEOUT_SECONDS = 45
STATUS_ENABLED = True
STATUS_WIDTH = 0
T = TypeVar("T")
WHISPER_REPO_BASE_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
VOICE_CONFIG_VERSION = 1
DEFAULT_HOTKEY = "Ctrl+Alt+space"
DEFAULT_LANGUAGE = "en"

X11_KEY_PRESS = 2
X11_SHIFT_MASK = 1 << 0
X11_LOCK_MASK = 1 << 1
X11_CONTROL_MASK = 1 << 2
X11_MOD1_MASK = 1 << 3
X11_MOD2_MASK = 1 << 4
X11_MOD4_MASK = 1 << 6
X11_GRAB_MODE_ASYNC = 1
X11_CURRENT_TIME = 0
X11_GRAB_SUCCESS = 0


class VoiceCliError(RuntimeError):
    """Expected CLI failure with a user-facing message."""


@dataclass(frozen=True)
class CommandResult:
    stdout: str
    stderr: str
    returncode: int


@dataclass(frozen=True)
class WhisperModel:
    key: str
    display_name: str
    filename: str
    size: str
    ram: str
    profile: str
    description: str

    @property
    def url(self) -> str:
        return f"{WHISPER_REPO_BASE_URL}/{self.filename}"

    def path(self) -> Path:
        return default_whisper_model_dir() / self.filename


@dataclass
class DownloadState:
    model: WhisperModel
    received: int = 0
    total: int | None = None
    done: bool = False
    error: str | None = None
    path: Path | None = None

    @property
    def fraction(self) -> float | None:
        if not self.total:
            return None
        return min(1.0, self.received / self.total)


@dataclass
class TuiModelState:
    active: WhisperModel | None
    custom_path: Path | None = None

    def active_path(self) -> Path | None:
        if self.active:
            return self.active.path()
        return self.custom_path

    def active_label(self) -> str:
        if self.active:
            return self.active.display_name
        if self.custom_path:
            return self.custom_path.name
        return "none"


@dataclass(frozen=True)
class LanguageOption:
    code: str
    label: str


@dataclass
class RecordingSession:
    process: subprocess.Popen[str]
    out_path: Path
    backend_name: str
    command: list[str | Path]
    started_at: float


@dataclass(frozen=True)
class HotkeyBinding:
    key_name: str
    keycode: int
    modifiers: int


@dataclass(frozen=True)
class PasteResult:
    clipboard_tool: str
    paste_tool: str | None
    paste_error: str | None = None


class XKeyEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", ctypes.c_ulong),
        ("root", ctypes.c_ulong),
        ("subwindow", ctypes.c_ulong),
        ("time", ctypes.c_ulong),
        ("x", ctypes.c_int),
        ("y", ctypes.c_int),
        ("x_root", ctypes.c_int),
        ("y_root", ctypes.c_int),
        ("state", ctypes.c_uint),
        ("keycode", ctypes.c_uint),
        ("same_screen", ctypes.c_int),
    ]


def should_show_status() -> bool:
    return STATUS_ENABLED and sys.stderr.isatty()


def render_status(message: str) -> None:
    global STATUS_WIDTH
    if not should_show_status():
        return

    padding = " " * max(0, STATUS_WIDTH - len(message))
    sys.stderr.write(f"\r{message}{padding}")
    sys.stderr.flush()
    STATUS_WIDTH = len(message)


def finish_status(message: str | None = None) -> None:
    global STATUS_WIDTH
    if not should_show_status():
        return

    if message is not None:
        render_status(message)

    sys.stderr.write("\n")
    sys.stderr.flush()
    STATUS_WIDTH = 0


def status(message: str) -> None:
    if should_show_status():
        finish_status(message)


def expand_path(value: str | None) -> Path | None:
    if value is None:
        return None
    return Path(value).expanduser().resolve()


def default_whisper_threads() -> int:
    return max(1, min(8, os.cpu_count() or 4))


def default_model_root() -> Path:
    data_home = os.environ.get("XDG_DATA_HOME")
    if data_home:
        return Path(data_home).expanduser() / "voice" / "models"
    return Path.home() / ".local" / "share" / "voice" / "models"


def default_whisper_model_dir() -> Path:
    return default_model_root() / "whisper"


def default_config_path() -> Path:
    config_home = os.environ.get("XDG_CONFIG_HOME")
    if config_home:
        return Path(config_home).expanduser() / "voice" / "config.json"
    return Path.home() / ".config" / "voice" / "config.json"


WHISPER_MODEL_CATALOG: tuple[WhisperModel, ...] = (
    WhisperModel(
        "tiny",
        "Tiny",
        "ggml-tiny.bin",
        "75 MiB",
        "~390 MiB RAM",
        "fastest",
        "Quick notes and low-power machines; lowest accuracy.",
    ),
    WhisperModel(
        "base",
        "Base",
        "ggml-base.bin",
        "142 MiB",
        "~500 MiB RAM",
        "fast default",
        "Recommended for slow CPU and quick notes.",
    ),
    WhisperModel(
        "small",
        "Small",
        "ggml-small.bin",
        "466 MiB",
        "~1.0 GiB RAM",
        "balanced default",
        "Recommended balanced CPU default.",
    ),
    WhisperModel(
        "medium",
        "Medium",
        "ggml-medium.bin",
        "1.5 GiB",
        "~2.6 GiB RAM",
        "slow accurate",
        "Expect slow CPU transcription; prefer Turbo for interactive dictation.",
    ),
    WhisperModel(
        "large-v3-turbo",
        "Large v3 Turbo",
        "ggml-large-v3-turbo.bin",
        "1.5 GiB",
        "~2.0 GiB RAM",
        "best fast accuracy",
        "Recommended best quality/speed tradeoff.",
    ),
    WhisperModel(
        "large-v3",
        "Large v3",
        "ggml-large-v3.bin",
        "3.1 GiB",
        "~4.7 GiB RAM",
        "very slow highest",
        "Best quality; use GPU acceleration or expect slow CPU runs.",
    ),
)

MODEL_NAME_WIDTH = max(len(model.display_name) for model in WHISPER_MODEL_CATALOG)


LANGUAGE_OPTIONS: tuple[LanguageOption, ...] = (
    LanguageOption("en", "English"),
    LanguageOption("auto", "Auto-detect"),
    LanguageOption("es", "Spanish"),
    LanguageOption("pt", "Portuguese"),
    LanguageOption("fr", "French"),
    LanguageOption("de", "German"),
    LanguageOption("it", "Italian"),
    LanguageOption("ja", "Japanese"),
    LanguageOption("zh", "Chinese"),
    LanguageOption("ko", "Korean"),
)


def language_label(code: str) -> str:
    for option in LANGUAGE_OPTIONS:
        if option.code == code:
            return f"{option.label} ({option.code})"
    return code


def model_by_key(key: str) -> WhisperModel | None:
    for model in WHISPER_MODEL_CATALOG:
        if model.key == key:
            return model
    return None


def model_for_path(path: Path) -> WhisperModel | None:
    for model in WHISPER_MODEL_CATALOG:
        if model.path() == path:
            return model
    return None


def downloaded_whisper_models() -> list[WhisperModel]:
    return [model for model in WHISPER_MODEL_CATALOG if model.path().is_file()]


def read_voice_config() -> dict[str, object]:
    config_path = default_config_path()
    if not config_path.is_file():
        return {}
    try:
        value = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def write_voice_config(config: dict[str, object]) -> None:
    config_path = default_config_path()
    config_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"version": VOICE_CONFIG_VERSION, **config}
    config_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_active_whisper_model() -> WhisperModel | None:
    key = read_voice_config().get("active_whisper_model")
    if isinstance(key, str):
        model = model_by_key(key)
        if model and model.path().is_file():
            return model
    downloaded = downloaded_whisper_models()
    for preferred_key in ("large-v3-turbo", "small", "base"):
        preferred = model_by_key(preferred_key)
        if preferred in downloaded:
            return preferred
    return downloaded[0] if downloaded else None


def save_active_whisper_model(model: WhisperModel) -> None:
    config = read_voice_config()
    config["active_whisper_model"] = model.key
    write_voice_config(config)


def clear_active_whisper_model() -> None:
    config = read_voice_config()
    config.pop("active_whisper_model", None)
    write_voice_config(config)


def load_hotkey() -> str:
    hotkey = read_voice_config().get("hotkey")
    return hotkey if isinstance(hotkey, str) and hotkey.strip() else DEFAULT_HOTKEY


def save_hotkey(hotkey: str) -> None:
    config = read_voice_config()
    config["hotkey"] = hotkey
    write_voice_config(config)


def resolve_hotkey(configured: str | None) -> str:
    return configured if configured else load_hotkey()


def load_language() -> str:
    language = read_voice_config().get("language")
    return language if isinstance(language, str) and language.strip() else DEFAULT_LANGUAGE


def save_language(language: str) -> None:
    config = read_voice_config()
    config["language"] = language
    write_voice_config(config)


def resolve_language(configured: str | None) -> str:
    return configured if configured else load_language()


def resolve_whisper_model(configured: str | None) -> Path:
    if configured:
        return require_file(configured, "Whisper model")
    model = load_active_whisper_model()
    if model:
        return model.path()
    raise VoiceCliError(
        "No Whisper model is configured. Run `voice tui`, press M, download a model, and activate it."
    )


def initial_tui_model_state(configured: str | None) -> TuiModelState:
    if configured:
        path = require_file(configured, "Whisper model")
        return TuiModelState(active=model_for_path(path), custom_path=path if model_for_path(path) is None else None)
    return TuiModelState(active=load_active_whisper_model())


def copy_to_clipboard(text: str) -> str:
    wl_copy = shutil.which("wl-copy")
    if wl_copy:
        try:
            completed = subprocess.run(
                [wl_copy],
                input=text,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise VoiceCliError(f"Clipboard copy failed using wl-copy: {exc}") from exc

        if completed.returncode == 0:
            return "wl-copy"

        details = completed.stderr.strip() or completed.stdout.strip() or f"exit code {completed.returncode}"
        raise VoiceCliError(f"Clipboard copy failed using wl-copy: {details}")

    for name, command in [
        ("xclip", ["xclip", "-selection", "clipboard"]),
        ("xsel", ["xsel", "--clipboard", "--input"]),
    ]:
        if not shutil.which(name):
            continue
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
                start_new_session=True,
            )
            assert process.stdin is not None
            process.stdin.write(text)
            process.stdin.close()
            time.sleep(0.2)
        except OSError as exc:
            raise VoiceCliError(f"Clipboard copy failed using {name}: {exc}") from exc

        if process.poll() is None:
            return name

        if process.returncode == 0:
            return name
        raise VoiceCliError(f"Clipboard copy failed using {name}: exit code {process.returncode}")

    if sys.stderr.isatty():
        encoded = base64.b64encode(text.encode("utf-8")).decode("ascii")
        sys.stderr.write(f"\033]52;c;{encoded}\a")
        sys.stderr.flush()
        return "OSC 52"

    raise VoiceCliError("Clipboard copy requires wl-copy, xclip, xsel, or an OSC 52-capable terminal.")


def auto_paste(delay_ms: int, paste_tool: str = "auto", paste_key: str = "auto") -> str:
    if delay_ms < 0:
        raise VoiceCliError("--paste-delay-ms cannot be negative.")

    command = paste_command(paste_tool, paste_key)
    ensure_paste_focus(command)

    if delay_ms:
        time.sleep(delay_ms / 1000)

    try:
        if command[0] == "x11-xtest":
            paste_with_x11_xtest(paste_key)
            return "x11-xtest"

        completed = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=2,
            check=False,
            env=tool_environment(command),
        )
    except subprocess.TimeoutExpired as exc:
        raise VoiceCliError(f"Auto-paste timed out using {Path(command[0]).name}.") from exc
    except OSError as exc:
        raise VoiceCliError(f"Auto-paste failed to start using {Path(command[0]).name}: {exc}") from exc

    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip() or f"exit code {completed.returncode}"
        raise VoiceCliError(f"Auto-paste failed using {Path(command[0]).name}: {details}")

    return Path(command[0]).name


def ensure_paste_focus(command: Sequence[str]) -> None:
    if command and command[0] == "x11-xtest":
        return
    if Path(command[0]).name != "xdotool":
        return
    try:
        completed = subprocess.run(
            [command[0], "getwindowfocus"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=1,
            check=False,
            env=tool_environment(command),
        )
    except subprocess.TimeoutExpired as exc:
        raise VoiceCliError("Auto-paste focus check timed out.") from exc
    except OSError as exc:
        raise VoiceCliError(f"Auto-paste focus check failed: {exc}") from exc
    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip() or f"exit code {completed.returncode}"
        raise VoiceCliError(f"Auto-paste could not find a focused X11 window: {details}")


_TERMINAL_WM_CLASSES: frozenset[str] = frozenset({
    "xterm", "uxterm",
    "gnome-terminal-server", "gnome-terminal",
    "konsole",
    "kitty",
    "alacritty",
    "tilix",
    "urxvt", "rxvt", "rxvt-unicode",
    "st",
    "terminator",
    "xfce4-terminal",
    "lxterminal",
    "mate-terminal",
    "termite",
    "wezterm-gui",
    "qterminal",
    "terminology",
    "foot",
    "ghostty",
})


def _detect_paste_key_x11(xdotool: str) -> str:
    """Query focused window WM_CLASS.

    Returns ctrl+v only when a non-terminal window is positively identified.
    Falls back to ctrl+shift+v on detection failure or unknown window class.
    """
    try:
        completed = subprocess.run(
            [xdotool, "getactivewindow", "getwindowclassname"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=1,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "ctrl+shift+v"
    if completed.returncode != 0:
        return "ctrl+shift+v"
    class_name = completed.stdout.strip().lower()
    if not class_name or class_name in _TERMINAL_WM_CLASSES:
        return "ctrl+shift+v"
    return "ctrl+v"


def paste_command(paste_tool: str, paste_key: str = "auto") -> list[str]:
    if paste_tool == "none":
        raise VoiceCliError("Auto-paste is disabled.")
    if paste_tool not in {"auto", "xdotool", "wtype"}:
        raise VoiceCliError(f"Unsupported paste tool: {paste_tool}")

    session_type = os.environ.get("XDG_SESSION_TYPE", "").lower()
    wayland = session_type == "wayland" or bool(os.environ.get("WAYLAND_DISPLAY"))
    x11 = bool(os.environ.get("DISPLAY"))

    if paste_tool in {"auto", "xdotool"} and x11:
        xdotool = shutil.which("xdotool")
        if xdotool:
            key = _detect_paste_key_x11(xdotool) if paste_key == "auto" else paste_key
            return [xdotool, "key", "--clearmodifiers", key]
        if paste_tool == "auto" and can_paste_with_x11_xtest():
            return ["x11-xtest"]
        if paste_tool == "xdotool":
            raise VoiceCliError("Auto-paste requires xdotool on X11.")

    if paste_tool in {"auto", "wtype"} and wayland:
        wtype = shutil.which("wtype")
        if wtype:
            key = "ctrl+shift+v" if paste_key == "auto" else paste_key
            return _wtype_command(wtype, key)
        if paste_tool == "wtype":
            raise VoiceCliError("Auto-paste requires wtype on Wayland.")

    if paste_tool == "auto":
        raise VoiceCliError("Auto-paste requires xdotool on X11 or wtype on Wayland.")
    raise VoiceCliError(f"Auto-paste tool is not usable in this session: {paste_tool}")


_WTYPE_KEY_NAMES: dict[str, str] = {
    "insert": "Insert",
}


def _wtype_command(wtype: str, paste_key: str) -> list[str]:
    """Build wtype command for a given key combo like ctrl+v or ctrl+shift+v."""
    parts = paste_key.lower().split("+")
    raw_key = parts[-1]
    key = _WTYPE_KEY_NAMES.get(raw_key, raw_key)
    modifiers = parts[:-1]
    cmd: list[str] = [wtype]
    for mod in modifiers:
        cmd += ["-M", mod]
    cmd += ["-k", key]
    for mod in reversed(modifiers):
        cmd += ["-m", mod]
    return cmd


def can_paste_with_x11_xtest() -> bool:
    return bool(os.environ.get("DISPLAY") and ctypes.util.find_library("X11") and ctypes.util.find_library("Xtst"))


def paste_with_x11_xtest(paste_key: str = "auto") -> None:
    if paste_key == "auto":
        paste_key = "ctrl+shift+v"
    x11_name = ctypes.util.find_library("X11")
    xtst_name = ctypes.util.find_library("Xtst")
    if not x11_name or not xtst_name:
        raise VoiceCliError("Auto-paste requires libX11 and libXtst for the XTest fallback.")

    x11 = ctypes.CDLL(x11_name)
    xtst = ctypes.CDLL(xtst_name)
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
    x11.XStringToKeysym.restype = ctypes.c_ulong
    x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XKeysymToKeycode.restype = ctypes.c_ubyte
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XFlush.restype = ctypes.c_int
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.restype = ctypes.c_int
    xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    xtst.XTestFakeKeyEvent.restype = ctypes.c_int

    _XTEST_KEYSYM_NAMES: dict[str, bytes] = {
        "ctrl": b"Control_L",
        "shift": b"Shift_L",
        "alt": b"Alt_L",
        "super": b"Super_L",
    }

    display = x11.XOpenDisplay(None)
    if not display:
        raise VoiceCliError("Auto-paste could not open the X11 display.")

    _XTEST_KEY_NAMES: dict[str, bytes] = {
        "insert": b"Insert",
    }

    try:
        parts = paste_key.lower().split("+")
        raw_key = parts[-1]
        key_name = _XTEST_KEY_NAMES.get(raw_key, raw_key.encode())
        modifier_names = [_XTEST_KEYSYM_NAMES.get(m) for m in parts[:-1]]
        if any(n is None for n in modifier_names):
            unknown = [m for m, n in zip(parts[:-1], modifier_names) if n is None]
            raise VoiceCliError(f"Auto-paste could not resolve modifier(s): {', '.join(unknown)}")

        modifier_codes = [int(x11.XKeysymToKeycode(display, x11.XStringToKeysym(n))) for n in modifier_names]
        key_code = int(x11.XKeysymToKeycode(display, x11.XStringToKeysym(key_name)))

        if any(c == 0 for c in modifier_codes) or key_code == 0:
            raise VoiceCliError(f"Auto-paste could not resolve keycodes for {paste_key}.")

        events: list[tuple[int, int]] = (
            [(c, 1) for c in modifier_codes]
            + [(key_code, 1), (key_code, 0)]
            + [(c, 0) for c in reversed(modifier_codes)]
        )
        for keycode, is_press in events:
            if xtst.XTestFakeKeyEvent(display, keycode, is_press, 0) == 0:
                raise VoiceCliError("Auto-paste failed to send XTest key event.")
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay(display)


def bundled_tool(name: str) -> str | None:
    candidate = Path(__file__).resolve().parent / "vendor" / name / "usr" / "bin" / name
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return None


def tool_environment(command: Sequence[str]) -> dict[str, str] | None:
    if not command:
        return None
    executable = Path(command[0])
    vendor_root = Path(__file__).resolve().parent / "vendor"
    try:
        executable.relative_to(vendor_root)
    except ValueError:
        return None

    lib_dir = executable.parents[2] / "lib" / "x86_64-linux-gnu"
    env = os.environ.copy()
    if lib_dir.is_dir():
        existing = env.get("LD_LIBRARY_PATH")
        env["LD_LIBRARY_PATH"] = f"{lib_dir}:{existing}" if existing else str(lib_dir)
    return env


def copy_and_maybe_paste(text: str, args: argparse.Namespace) -> PasteResult:
    clipboard_tool = copy_to_clipboard(text)
    if not getattr(args, "auto_paste", False):
        return PasteResult(clipboard_tool, None)

    try:
        paste_tool = auto_paste(getattr(args, "paste_delay_ms", 120), getattr(args, "paste_tool", "auto"), getattr(args, "paste_key", "auto"))
        return PasteResult(clipboard_tool, paste_tool)
    except VoiceCliError as exc:
        return PasteResult(clipboard_tool, None, str(exc))


def resolve_executable(configured: str | None, names: Sequence[str]) -> Path:
    if configured:
        path = expand_path(configured)
        if path is None:
            raise VoiceCliError("Executable path is empty.")
        if not path.exists():
            raise VoiceCliError(f"Executable not found: {path}")
        if not os.access(path, os.X_OK):
            raise VoiceCliError(f"Executable is not runnable: {path}")
        return path

    for name in names:
        found = shutil.which(name)
        if found:
            return Path(found).resolve()

    display = ", ".join(names)
    raise VoiceCliError(f"Could not find any executable on PATH: {display}")


def require_file(path: str, label: str) -> Path:
    resolved = expand_path(path)
    if resolved is None or not resolved.exists():
        raise VoiceCliError(f"{label} not found: {path}")
    if resolved.is_dir():
        raise VoiceCliError(f"{label} points to a directory, not a file: {resolved}")
    return resolved


def run_command(
    args: Sequence[str | Path],
    timeout: float | None = None,
    status_label: str | None = None,
) -> CommandResult:
    printable = " ".join(shlex.quote(str(arg)) for arg in args)

    if status_label and should_show_status():
        return run_command_with_status(args, printable, timeout, status_label)

    try:
        completed = subprocess.run(
            [str(arg) for arg in args],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise VoiceCliError(f"Command timed out after {int(timeout or 0)} seconds: {printable}") from exc
    except OSError as exc:
        raise VoiceCliError(f"Command failed to start: {printable}\n{exc}") from exc

    return CommandResult(
        stdout=completed.stdout,
        stderr=completed.stderr,
        returncode=completed.returncode,
    )


def run_command_with_status(
    args: Sequence[str | Path],
    printable: str,
    timeout: float | None,
    status_label: str,
) -> CommandResult:
    try:
        process = subprocess.Popen(
            [str(arg) for arg in args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise VoiceCliError(f"Command failed to start: {printable}\n{exc}") from exc

    spinner = "|/-\\"
    start = time.monotonic()
    frame = 0

    while process.poll() is None:
        elapsed = time.monotonic() - start
        render_status(f"{status_label} {spinner[frame % len(spinner)]} {elapsed:0.1f}s")
        frame += 1

        if timeout is not None and elapsed > timeout:
            process.terminate()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
            finish_status(f"{status_label} timed out after {int(timeout)}s")
            raise VoiceCliError(f"Command timed out after {int(timeout)} seconds: {printable}")

        time.sleep(0.1)

    stdout, stderr = process.communicate()
    elapsed = time.monotonic() - start
    finish_status(f"{status_label} done in {elapsed:0.1f}s")
    return CommandResult(stdout=stdout or "", stderr=stderr or "", returncode=process.returncode or 0)


def download_whisper_model(model: WhisperModel, state: DownloadState) -> Path:
    target = model.path()
    if target.is_file():
        state.done = True
        state.path = target
        return target

    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix + ".part")

    request = urllib.request.Request(model.url, headers={"User-Agent": "voice-cli/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            total_header = response.headers.get("Content-Length")
            state.total = int(total_header) if total_header and total_header.isdigit() else None
            with partial.open("wb") as output:
                while True:
                    chunk = response.read(1024 * 256)
                    if not chunk:
                        break
                    output.write(chunk)
                    state.received += len(chunk)
    except (OSError, urllib.error.URLError) as exc:
        state.error = str(exc)
        try:
            partial.unlink()
        except FileNotFoundError:
            pass
        raise VoiceCliError(f"Download failed for {model.display_name}: {exc}") from exc

    partial.replace(target)
    state.done = True
    state.path = target
    return target


def format_bytes(value: int) -> str:
    amount = float(value)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if amount < 1024 or unit == "GiB":
            return f"{amount:0.1f} {unit}"
        amount /= 1024
    return f"{amount:0.1f} GiB"


def audio_duration_seconds(path: Path) -> float | None:
    try:
        with wave.open(str(path), "rb") as wav:
            frames = wav.getnframes()
            rate = wav.getframerate()
            if rate <= 0:
                return None
            return frames / rate
    except (OSError, wave.Error):
        return None


def prepare_audio_for_transcription(
    audio_path: Path,
    args: argparse.Namespace,
    work_dir: Path | None = None,
) -> tuple[Path, str | None]:
    if not getattr(args, "trim_silence", True):
        return audio_path, None

    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return audio_path, "Silence trim skipped: ffmpeg not found."

    threshold = getattr(args, "trim_silence_threshold", "-45dB")
    silence_seconds = max(0, getattr(args, "trim_silence_ms", 250)) / 1000
    min_speech_seconds = max(0.0, getattr(args, "min_speech_seconds", 0.25))
    original_duration = audio_duration_seconds(audio_path)
    trim_dir = work_dir or audio_path.parent
    trimmed_path = trim_dir / f"{audio_path.stem}-trimmed.wav"
    filter_expr = (
        "silenceremove="
        f"start_periods=1:start_duration={silence_seconds:0.3f}:start_threshold={threshold}:"
        f"stop_periods=1:stop_duration={silence_seconds:0.3f}:stop_threshold={threshold}"
    )
    try:
        completed = subprocess.run(
            [
                ffmpeg,
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(audio_path),
                "-af",
                filter_expr,
                str(trimmed_path),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return audio_path, f"Silence trim skipped: {exc}"

    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip() or f"exit code {completed.returncode}"
        return audio_path, f"Silence trim skipped: {details}"
    if not trimmed_path.is_file() or trimmed_path.stat().st_size <= 44:
        raise VoiceCliError("No speech detected after trimming silence.")

    trimmed_duration = audio_duration_seconds(trimmed_path)
    if trimmed_duration is not None and trimmed_duration < min_speech_seconds:
        raise VoiceCliError(f"No speech detected after trimming silence ({trimmed_duration:0.1f}s).")
    if original_duration is None or trimmed_duration is None:
        return trimmed_path, "Silence trim applied."
    if trimmed_duration < max(0.1, original_duration - 0.05):
        return trimmed_path, f"Silence trim: {original_duration:0.1f}s -> {trimmed_duration:0.1f}s."
    return audio_path, f"Silence trim: no material change ({original_duration:0.1f}s)."


def transcribe_audio(
    audio_path: Path,
    whisper_model: Path,
    whisper_cli: Path,
    language: str,
    timeout: float | None,
    threads: int,
    beam_size: int,
    best_of: int,
    fallback: bool,
    max_context: int,
) -> str:
    if threads <= 0:
        raise VoiceCliError("--whisper-threads must be greater than zero.")
    if beam_size <= 0:
        raise VoiceCliError("--whisper-beam-size must be greater than zero.")
    if best_of <= 0:
        raise VoiceCliError("--whisper-best-of must be greater than zero.")
    if max_context < -1:
        raise VoiceCliError("--whisper-max-context must be -1 or greater.")

    with tempfile.TemporaryDirectory(prefix="voice-transcript-") as temp_dir:
        output_base = Path(temp_dir) / "transcript"
        output_txt = output_base.with_suffix(".txt")
        args: list[str | Path] = [
            whisper_cli,
            "--model",
            whisper_model,
            "--file",
            audio_path,
            "--output-txt",
            "--output-file",
            output_base,
            "--no-prints",
            "--no-timestamps",
            "--language",
            language,
            "--threads",
            str(threads),
            "--beam-size",
            str(beam_size),
            "--best-of",
            str(best_of),
            "--max-context",
            str(max_context),
        ]
        if not fallback:
            args.append("--no-fallback")

        result = run_command(args, timeout=timeout, status_label="Transcribing")
        if result.returncode != 0:
            details = result.stderr.strip() or result.stdout.strip()
            raise VoiceCliError(f"whisper-cli failed with exit code {result.returncode}.\n{details}")

        if output_txt.exists():
            transcript = output_txt.read_text(encoding="utf-8")
        else:
            transcript = result.stdout

    cleaned = transcript.strip()
    if not cleaned:
        raise VoiceCliError("whisper-cli produced an empty transcript.")
    return cleaned


def heuristic_refine(text: str) -> str:
    without_fillers = re.sub(r"(?i)(^|[\s,.;!?])(?:um+|uh+|ah+|er+)(?=$|[\s,.;!?])", " ", text)
    collapsed = re.sub(r"\s+", " ", without_fillers)
    collapsed = re.sub(r"\s+([,.;!?])", r"\1", collapsed).strip()
    if not collapsed:
        raise VoiceCliError("The heuristic refinement step removed the entire transcript.")

    capitalized = collapsed[:1].upper() + collapsed[1:]
    if capitalized[-1] not in ".!?":
        capitalized += "."
    return capitalized


def build_llama_prompt(raw_text: str, profile: str) -> str:
    profile_instructions = {
        "literal": "Make the smallest edits necessary for punctuation and capitalization.",
        "balanced": "Clean obvious dictation artifacts while preserving the speaker's wording.",
        "polished": "Make the dictation read naturally while preserving the original meaning.",
    }[profile]

    return f"""You are a local dictation refinement engine.
Follow every rule exactly:
- Preserve the speaker's meaning.
- Keep the original language.
- Fix punctuation and capitalization.
- Remove filler words and obvious false starts.
- Do not add explanations, lists, or extra content.
- Return only the cleaned dictation as plain text.
- Do not repeat the instructions or raw dictation.

Tone profile:
{profile_instructions}

Raw dictation:
{raw_text}

Cleaned dictation:
"""


def refinement_executable(configured: str | None) -> Path:
    llama_cli = resolve_executable(configured, ("llama-cli", "llama-completion"))
    if llama_cli.name != "llama-cli":
        return llama_cli

    completion = llama_cli.with_name("llama-completion")
    if completion.exists() and os.access(completion, os.X_OK):
        return completion
    return llama_cli


def extract_refined_text(output: str, prompt: str) -> str:
    cleaned = output.replace(prompt, "")
    cleaned = cleaned.replace("<br>", "\n")
    cleaned = re.sub(r"(?m)^Refined text:\s*", "", cleaned)
    cleaned = re.sub(r"(?m)^Cleaned dictation:\s*", "", cleaned).strip()

    if cleaned.startswith('"') and cleaned.endswith('"') and len(cleaned) > 1:
        cleaned = cleaned[1:-1]

    collected: list[str] = []
    for raw_line in cleaned.splitlines():
        line = raw_line.strip()
        if not line:
            if collected:
                break
            continue

        if (
            line.startswith("### ")
            or line.startswith("You are a local dictation")
            or line.startswith("Tone profile:")
            or line.startswith("Raw dictation:")
        ):
            if collected:
                break
            continue

        if line in {"Cleaned dictation:", "<result>", "</result>"}:
            continue

        if is_sentinel_line(line):
            if collected:
                break
            continue

        collected.append(line)

    final = " ".join(collected).strip()
    return strip_trailing_sentinels(final)


def is_sentinel_line(line: str) -> bool:
    return line.strip().lower() in {"[end of text]", "<|endoftext|>", "<end_of_turn>", "</s>"}


def strip_trailing_sentinels(text: str) -> str:
    cleaned = text.strip()
    patterns = [
        r"\s*\[end of text\]\s*$",
        r"\s*<\|endoftext\|>\s*$",
        r"\s*<end_of_turn>\s*$",
        r"\s*</s>\s*$",
    ]
    for pattern in patterns:
        cleaned = re.sub(pattern, "", cleaned).strip()
    return cleaned


def llama_refine(text: str, llama_model: Path, llama_cli: Path, profile: str, timeout: float) -> str:
    executable = refinement_executable(str(llama_cli))
    prompt = build_llama_prompt(text, profile)
    result = run_command(
        [
            executable,
            "-m",
            llama_model,
            "-n",
            "128",
            "-no-cnv",
            "--simple-io",
            "--no-warmup",
            "--temp",
            "0",
            "--top-k",
            "1",
            "-p",
            prompt,
        ],
        timeout=timeout,
        status_label=f"Refining with {executable.name}",
    )
    if result.returncode != 0:
        details = result.stderr.strip() or result.stdout.strip()
        raise VoiceCliError(f"{executable.name} failed with exit code {result.returncode}.\n{details}")

    refined = extract_refined_text(result.stdout, prompt)
    if not refined:
        raise VoiceCliError("The local LLM returned an empty refinement.")
    return refined


def available_command(name: str) -> bool:
    return shutil.which(name) is not None


def whisper_backend_summary(whisper_cli: Path) -> str:
    target = wrapped_executable_target(whisper_cli)
    try:
        completed = subprocess.run(
            ["ldd", str(target)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"unknown ({exc})"

    output = f"{completed.stdout}\n{completed.stderr}".lower()
    backends: list[str] = []
    for token, label in [
        ("ggml-vulkan", "Vulkan"),
        ("ggml-cuda", "CUDA"),
        ("ggml-metal", "Metal"),
        ("ggml-openvino", "OpenVINO"),
        ("ggml-blas", "BLAS"),
    ]:
        if token in output:
            backends.append(label)
    if backends:
        return ", ".join(backends)
    if "ggml-cpu" in output:
        return "CPU-only"
    return "unknown"


def wrapped_executable_target(path: Path) -> Path:
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped.startswith("exec "):
                    continue
                parts = shlex.split(stripped)
                if len(parts) >= 2:
                    candidate = Path(parts[1]).expanduser()
                    if candidate.is_file():
                        return candidate
    except (OSError, UnicodeDecodeError, ValueError):
        pass
    return path


def record_command_candidates(out_path: Path, backend: str) -> list[list[str | Path]]:
    candidates: list[tuple[str, list[str | Path]]] = [
        (
            "pw-record",
            [
                "pw-record",
                "--rate",
                str(SAMPLE_RATE),
                "--channels",
                str(CHANNELS),
                "--format",
                "s16",
                out_path,
            ],
        ),
        (
            "arecord",
            [
                "arecord",
                "-f",
                "S16_LE",
                "-r",
                str(SAMPLE_RATE),
                "-c",
                str(CHANNELS),
                out_path,
            ],
        ),
        (
            "ffmpeg",
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "pulse",
                "-i",
                "default",
                "-ar",
                str(SAMPLE_RATE),
                "-ac",
                str(CHANNELS),
                "-c:a",
                "pcm_s16le",
                out_path,
            ],
        ),
    ]

    if backend == "auto":
        return [command for executable, command in candidates if available_command(executable)]

    for executable, command in candidates:
        if backend == executable:
            if not available_command(executable):
                raise VoiceCliError(f"Requested audio backend is not available on PATH: {backend}")
            return [command]

    raise VoiceCliError(f"Unsupported audio backend: {backend}")


def stop_recording(process: subprocess.Popen[str]) -> tuple[str, str, int]:
    if process.poll() is not None:
        stdout, stderr = process.communicate()
        return stdout or "", stderr or "", process.returncode or 0

    process.send_signal(signal.SIGINT)
    try:
        stdout, stderr = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            stdout, stderr = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
    return stdout or "", stderr or "", process.returncode or 0


def wait_for_recording(process: subprocess.Popen[str], seconds: float, backend_name: str) -> None:
    if not should_show_status():
        time.sleep(seconds)
        return

    start = time.monotonic()
    end = start + seconds

    while process.poll() is None:
        remaining = end - time.monotonic()
        if remaining <= 0:
            break
        render_status(f"Recording with {backend_name}: {remaining:0.1f}s left")
        time.sleep(min(0.2, remaining))

    finish_status(f"Recording with {backend_name}: stopping")


def start_recording_session(out_path: Path, backend: str) -> RecordingSession:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    commands = record_command_candidates(out_path, backend)
    if not commands:
        raise VoiceCliError("No supported recorder found. Install pipewire, alsa-utils, or ffmpeg.")

    errors: list[str] = []
    for command in commands:
        if out_path.exists():
            out_path.unlink()

        backend_name = Path(str(command[0])).name
        status(f"Trying recorder: {backend_name}")
        printable = " ".join(shlex.quote(str(arg)) for arg in command)
        try:
            process = subprocess.Popen(
                [str(arg) for arg in command],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except OSError as exc:
            errors.append(f"{printable}\n{exc}")
            continue

        deadline = time.monotonic() + 0.15
        while time.monotonic() < deadline:
            if out_path.exists() and out_path.stat().st_size > 44:
                break
            time.sleep(0.01)
        if process.poll() is None:
            return RecordingSession(process, out_path, backend_name, command, time.monotonic())

        stdout, stderr, returncode = stop_recording(process)
        errors.append(stderr.strip() or stdout.strip() or f"{printable} exited with {returncode}")

    raise VoiceCliError("Recording failed to start.\n" + "\n".join(error for error in errors if error))


def finish_recording_session(session: RecordingSession) -> Path:
    stdout, stderr, returncode = stop_recording(session.process)
    if session.out_path.exists() and session.out_path.stat().st_size > 0:
        status(f"Captured audio: {session.out_path}")
        return session.out_path

    printable = " ".join(shlex.quote(str(arg)) for arg in session.command)
    if returncode not in (0, -signal.SIGINT):
        details = stderr.strip() or stdout.strip() or f"{printable} exited with {returncode}"
        raise VoiceCliError(f"Recording failed.\n{details}")

    details = stderr.strip() or stdout.strip() or f"{printable} produced no audio file."
    raise VoiceCliError(f"Recording failed.\n{details}")


def record_audio(out_path: Path, backend: str, seconds: float | None) -> Path:
    if seconds is not None and seconds <= 0:
        raise VoiceCliError("--seconds must be greater than zero.")

    session = start_recording_session(out_path, backend)

    if seconds is None:
        if not sys.stdin.isatty():
            session.process.terminate()
            raise VoiceCliError("Interactive recording requires a terminal. Pass --seconds in non-interactive sessions.")
        print(f"Recording with {session.backend_name}. Press Enter to stop.", file=sys.stderr)
        input()
    else:
        wait_for_recording(session.process, seconds, session.backend_name)

    return finish_recording_session(session)


def refine_text(text: str, args: argparse.Namespace, llama_model: Path | None, llama_cli: Path | None) -> str:
    if args.refine == "none":
        return text
    if args.refine == "heuristic":
        return heuristic_refine(text)

    assert llama_model is not None
    assert llama_cli is not None
    return llama_refine(text, llama_model, llama_cli, args.profile, args.llama_timeout)


def read_text_arg_or_stdin(text: str | None) -> str:
    if text is not None:
        return text
    if sys.stdin.isatty():
        raise VoiceCliError("No text provided. Pass --text or pipe text on stdin.")
    value = sys.stdin.read()
    if not value.strip():
        raise VoiceCliError("stdin did not contain any text.")
    return value


def command_doctor(args: argparse.Namespace) -> int:
    model_root = default_model_root()
    checks: list[tuple[str, bool, str]] = []
    check_map: dict[str, bool] = {}
    explicit_model_paths_ok = True
    whisper_cli_path: Path | None = None

    for label, configured, names in [
        ("whisper-cli", args.whisper_cli, ("whisper-cli",)),
        ("llama-cli", args.llama_cli, ("llama-cli", "llama-completion")),
        ("ffmpeg", None, ("ffmpeg",)),
        ("pw-record", None, ("pw-record",)),
        ("arecord", None, ("arecord",)),
        ("xdotool", None, ("xdotool",)),
        ("wtype", None, ("wtype",)),
        ("x11-xtest", None, ("x11-xtest",)),
        ("vulkaninfo", None, ("vulkaninfo",)),
        ("nvidia-smi", None, ("nvidia-smi",)),
    ]:
        try:
            if label == "x11-xtest" and can_paste_with_x11_xtest():
                resolved = Path("libX11/libXtst")
            elif label == "x11-xtest":
                raise VoiceCliError("X11 XTest fallback requires DISPLAY, libX11, and libXtst.")
            else:
                resolved = resolve_executable(configured, names)
            if label == "whisper-cli":
                whisper_cli_path = resolved
            checks.append((label, True, str(resolved)))
            check_map[label] = True
        except VoiceCliError as exc:
            checks.append((label, False, str(exc)))
            check_map[label] = False

    if args.whisper_model:
        path = expand_path(args.whisper_model)
        ok = bool(path and path.is_file())
        explicit_model_paths_ok = explicit_model_paths_ok and ok
        checks.append(("whisper model", ok, str(path)))
    if args.llama_model:
        path = expand_path(args.llama_model)
        ok = bool(path and path.is_file())
        explicit_model_paths_ok = explicit_model_paths_ok and ok
        checks.append(("llama model", ok, str(path)))

    active_model = load_active_whisper_model()
    print(f"Model root: {model_root}")
    print(f"Active Whisper model: {active_model.display_name if active_model else 'none'}")
    print(f"Global hotkey: {load_hotkey()}")
    print(f"Language: {language_label(load_language())}")
    print(f"CPU threads: {os.cpu_count() or 'unknown'}")
    if whisper_cli_path:
        backend = whisper_backend_summary(whisper_cli_path)
        print(f"Whisper backend: {backend}")
        if backend == "CPU-only" and (os.cpu_count() or 0) <= 4:
            print("Recommendation: use Large v3 Turbo, Small, or Base for interactive latency; avoid Medium/Large v3 on CPU-only slow machines.")
    print("Whisper catalog:")
    for model in WHISPER_MODEL_CATALOG:
        state = "downloaded" if model.path().is_file() else "available"
        print(f"  {model.display_name:{MODEL_NAME_WIDTH}} {state:10} {model.size:8} {model.ram:13} {model.profile}")
    for label, ok, details in checks:
        marker = "OK" if ok else "MISSING"
        print(f"{marker:7} {label:14} {details}")

    recorder_ok = check_map.get("pw-record", False) or check_map.get("arecord", False) or check_map.get("ffmpeg", False)
    required_ok = check_map.get("whisper-cli", False) and recorder_ok and explicit_model_paths_ok
    return 0 if required_ok else 1


def command_record(args: argparse.Namespace) -> int:
    out_path = expand_path(args.out)
    if out_path is None:
        raise VoiceCliError("Output path is required.")
    recorded = record_audio(out_path, args.backend, args.seconds)
    print(recorded)
    return 0


def command_transcribe(args: argparse.Namespace) -> int:
    audio = require_file(args.audio, "Audio file")
    whisper_model = require_file(args.model, "Whisper model")
    whisper_cli = resolve_executable(args.whisper_cli, ("whisper-cli",))
    args.language = resolve_language(args.language)
    status(f"Audio: {audio}")
    status(f"Whisper model: {whisper_model}")
    with tempfile.TemporaryDirectory(prefix="voice-trimmed-audio-") as temp_dir:
        transcribe_audio_path, trim_message = prepare_audio_for_transcription(audio, args, Path(temp_dir))
        if trim_message:
            status(trim_message)
        transcript = transcribe_audio(
            transcribe_audio_path,
            whisper_model,
            whisper_cli,
            args.language,
            args.timeout,
            args.whisper_threads,
            args.whisper_beam_size,
            args.whisper_best_of,
            args.whisper_fallback,
            args.whisper_max_context,
        )
    print(transcript)
    return 0


def command_refine(args: argparse.Namespace) -> int:
    text = read_text_arg_or_stdin(args.text)
    if args.backend == "none":
        print(text.strip())
        return 0
    if args.backend == "heuristic":
        status("Refining with heuristic cleanup")
        print(heuristic_refine(text))
        return 0

    if not args.model:
        raise VoiceCliError("--model is required when --backend llama is selected.")
    llama_model = require_file(args.model, "Llama model")
    llama_cli = resolve_executable(args.llama_cli, ("llama-cli", "llama-completion"))
    print(llama_refine(text, llama_model, llama_cli, args.profile, args.timeout))
    return 0


def command_run(args: argparse.Namespace) -> int:
    whisper_model = resolve_whisper_model(args.whisper_model)
    whisper_cli = resolve_executable(args.whisper_cli, ("whisper-cli",))
    args.language = resolve_language(args.language)
    if args.refine == "llama" and not args.llama_model:
        raise VoiceCliError("--llama-model is required when --refine llama is selected.")
    llama_model = require_file(args.llama_model, "Llama model") if args.refine == "llama" else None
    llama_cli = resolve_executable(args.llama_cli, ("llama-cli", "llama-completion")) if args.refine == "llama" else None

    status("Starting Voice terminal pipeline")
    status(f"Whisper model: {whisper_model}")
    status(
        "Whisper decode: "
        f"language={args.language}, threads={args.whisper_threads}, "
        f"beam={args.whisper_beam_size}, best-of={args.whisper_best_of}, "
        f"fallback={'on' if args.whisper_fallback else 'off'}"
    )
    status(f"Refinement: {args.refine}")

    with tempfile.TemporaryDirectory(prefix="voice-audio-") as temp_dir:
        audio_path = Path(temp_dir) / "recording.wav"
        record_start = time.monotonic()
        record_audio(audio_path, args.backend, args.seconds)
        duration = audio_duration_seconds(audio_path)
        status(f"Recording step completed in {time.monotonic() - record_start:0.1f}s")
        if duration is not None:
            status(f"Audio duration: {duration:0.1f}s")
        transcribe_audio_path, trim_message = prepare_audio_for_transcription(audio_path, args, Path(temp_dir))
        if trim_message:
            status(trim_message)
        transcribe_start = time.monotonic()
        transcript = transcribe_audio(
            transcribe_audio_path,
            whisper_model,
            whisper_cli,
            args.language,
            args.whisper_timeout,
            args.whisper_threads,
            args.whisper_beam_size,
            args.whisper_best_of,
            args.whisper_fallback,
            args.whisper_max_context,
        )
        status(f"Transcription completed in {time.monotonic() - transcribe_start:0.1f}s")

    if args.refine == "heuristic":
        status("Refining with heuristic cleanup")
    refine_start = time.monotonic()
    final_text = refine_text(transcript, args, llama_model, llama_cli)
    status(f"Refinement completed in {time.monotonic() - refine_start:0.1f}s")

    try:
        paste_result = copy_and_maybe_paste(final_text, args)
        status(f"Copied final output to clipboard with {paste_result.clipboard_tool}")
        if paste_result.paste_tool:
            status(f"Pasted final output with {paste_result.paste_tool}")
        elif paste_result.paste_error:
            status(paste_result.paste_error)
    except VoiceCliError as exc:
        status(str(exc))

    status("Done")
    print(final_text)
    return 0


class TuiView:
    def __init__(self, screen: curses.window, model_state: TuiModelState, language: str, hotkey: str = "") -> None:
        self.screen = screen
        self.phase = "Ready"
        self.detail = "Idle"
        self.hotkey = hotkey
        self.model_state = model_state
        self.language = language
        self.logs: list[str] = []
        self.output = ""
        self.spinner_frame = 0

        try:
            curses.curs_set(0)
        except curses.error:
            pass
        screen.nodelay(True)
        screen.keypad(True)

    def set_phase(self, phase: str, detail: str = "") -> None:
        self.phase = phase
        self.detail = detail
        self.draw()

    def add_log(self, message: str) -> None:
        timestamp = time.strftime("%H:%M:%S")
        self.logs.append(f"{timestamp}  {message}")
        self.logs = self.logs[-80:]
        self.draw()

    def set_output(self, text: str) -> None:
        self.output = text
        self.draw()

    def set_hotkey(self, hotkey: str) -> None:
        self.hotkey = hotkey
        self.draw()

    def set_model_state(self, model_state: TuiModelState) -> None:
        self.model_state = model_state
        self.draw()

    def set_language(self, language: str) -> None:
        self.language = language
        self.draw()

    def spin(self, phase: str, detail: str = "") -> None:
        spinner = "|/-\\"
        self.spinner_frame += 1
        self.phase = f"{phase} {spinner[self.spinner_frame % len(spinner)]}"
        self.detail = detail
        self.draw()

    def draw(self) -> None:
        height, width = self.screen.getmaxyx()
        self.screen.erase()

        if height < 18 or width < 60:
            self.add_text(0, 0, "Voice TUI needs at least 60x18.", curses.A_BOLD)
            self.screen.refresh()
            return

        self.add_text(0, 0, "Voice Linux TUI MVP", curses.A_BOLD)
        self.add_text(1, 0, f"Phase: {self.phase}")
        self.add_text(2, 0, f"Detail: {self.detail}")
        self.add_text(3, 0, f"Global hotkey: {self.hotkey or 'disabled'}")
        self.add_text(4, 0, f"Active Whisper model: {self.model_state.active_label()}")
        self.add_text(5, 0, f"Language: {language_label(self.language)}")
        self.add_text(6, 0, "Controls: R record | M models | L language | H shortcut | Q quit")

        model_top = 8
        model_height = 8
        log_top = model_top + model_height + 1
        log_height = max(4, height // 5)
        output_top = log_top + log_height + 1
        output_height = max(3, height - output_top - 1)

        self.draw_section(model_top, model_height, "Models", self.model_status_lines())
        self.draw_section(log_top, log_height, "Log", self.logs[-(log_height - 2):])
        self.draw_section(output_top, output_height, "Output", self.wrap_lines(self.output, width - 4))
        self.screen.refresh()

    def model_status_lines(self) -> list[str]:
        lines: list[str] = []
        for model in WHISPER_MODEL_CATALOG:
            downloaded = model.path().is_file()
            active = self.model_state.active == model
            state = "active" if active else "downloaded" if downloaded else "available"
            lines.append(f"{model.display_name:{MODEL_NAME_WIDTH}} {state:10} {model.size:8} {model.ram:13} {model.profile}")
        if self.model_state.custom_path:
            lines.append(f"{'Custom':{MODEL_NAME_WIDTH}} active     {self.model_state.custom_path}")
        return lines

    def draw_section(self, top: int, height: int, title: str, lines: Sequence[str]) -> None:
        screen_height, width = self.screen.getmaxyx()
        if top >= screen_height:
            return

        bottom = min(top + height - 1, screen_height - 1)
        self.add_text(top, 0, f"+ {title} " + "-" * max(0, width - len(title) - 5), curses.A_BOLD)
        for index, line in enumerate(lines[: max(0, bottom - top - 1)], start=top + 1):
            self.add_text(index, 1, line)
        self.add_text(bottom, 0, "-" * max(0, width - 1))

    def add_text(self, y: int, x: int, text: str, attr: int = 0) -> None:
        height, width = self.screen.getmaxyx()
        if y < 0 or y >= height or x >= width:
            return
        try:
            self.screen.addnstr(y, x, text, max(0, width - x - 1), attr)
        except curses.error:
            pass

    @staticmethod
    def wrap_lines(text: str, width: int) -> list[str]:
        if not text:
            return []
        lines: list[str] = []
        for paragraph in text.splitlines() or [text]:
            wrapped = textwrap.wrap(paragraph, width=max(20, width), replace_whitespace=False)
            lines.extend(wrapped or [""])
        return lines


def activate_tui_model(view: TuiView, model_state: TuiModelState, model: WhisperModel) -> None:
    if not model.path().is_file():
        raise VoiceCliError(f"{model.display_name} is not downloaded yet.")
    model_state.active = model
    model_state.custom_path = None
    save_active_whisper_model(model)
    view.set_model_state(model_state)
    view.add_log(f"Active Whisper model: {model.display_name}.")


def delete_tui_model(view: TuiView, model_state: TuiModelState, model: WhisperModel) -> None:
    target = model.path()
    if not target.is_file():
        raise VoiceCliError(f"{model.display_name} is not downloaded.")

    target.unlink()
    partial = target.with_suffix(target.suffix + ".part")
    try:
        partial.unlink()
    except FileNotFoundError:
        pass

    if model_state.active == model:
        model_state.active = None
        clear_active_whisper_model()
        next_models = downloaded_whisper_models()
        if next_models:
            activate_tui_model(view, model_state, next_models[0])
        else:
            view.set_model_state(model_state)

    view.add_log(f"Deleted Whisper model: {model.display_name}.")


def draw_progress_bar(fraction: float | None, width: int) -> str:
    width = max(8, width)
    if fraction is None:
        return "[" + ("?" * width) + "]"
    filled = min(width, max(0, int(width * fraction)))
    return "[" + ("#" * filled) + ("-" * (width - filled)) + "]"


def model_detail_lines(model: WhisperModel, download: DownloadState | None) -> list[str]:
    lines = [
        f"Model: {model.display_name}",
        f"File: {model.filename}",
        f"Size: {model.size}",
        f"RAM: {model.ram}",
        f"Profile: {model.profile}",
        model.description,
    ]
    if download:
        if download.error:
            lines.append(f"Download error: {download.error}")
        elif download.done:
            lines.append("Download complete.")
        elif download.total:
            lines.append(f"Downloading: {format_bytes(download.received)} / {format_bytes(download.total)}")
        else:
            lines.append(f"Downloading: {format_bytes(download.received)}")
    return lines


def run_model_manager(view: TuiView, model_state: TuiModelState) -> None:
    screen = view.screen
    selected = 0
    downloads: dict[str, DownloadState] = {}
    download_threads: dict[str, threading.Thread] = {}

    def start_download(model: WhisperModel) -> None:
        if model.path().is_file():
            activate_tui_model(view, model_state, model)
            return
        if model.key in download_threads and download_threads[model.key].is_alive():
            return

        state = DownloadState(model)
        downloads[model.key] = state

        def worker() -> None:
            try:
                download_whisper_model(model, state)
            except BaseException as exc:
                state.error = str(exc)

        thread = threading.Thread(target=worker, daemon=True)
        download_threads[model.key] = thread
        thread.start()
        view.add_log(f"Downloading Whisper model: {model.display_name}.")

    while True:
        height, width = screen.getmaxyx()
        screen.erase()
        if height < 18 or width < 70:
            view.add_text(0, 0, "Model manager needs at least 70x18.", curses.A_BOLD)
            screen.refresh()
            time.sleep(0.1)
            key = screen.getch()
            if key in (ord("q"), ord("Q"), 27):
                return
            continue

        view.add_text(0, 0, "Whisper Model Manager", curses.A_BOLD)
        view.add_text(1, 0, f"Active: {model_state.active_label()}")
        view.add_text(2, 0, "Controls: Up/Down select | Enter/D download | A activate | X delete | Q close")

        for index, model in enumerate(WHISPER_MODEL_CATALOG):
            download = downloads.get(model.key)
            downloaded = model.path().is_file()
            active = model_state.active == model
            if download and download.error:
                state = "error"
            elif download and not download.done:
                state = "downloading"
            elif active:
                state = "active"
            elif downloaded:
                state = "downloaded"
            else:
                state = "available"

            marker = ">" if index == selected else " "
            attr = curses.A_REVERSE if index == selected else 0
            line = f"{marker} {model.display_name:{MODEL_NAME_WIDTH}} {state:11} {model.size:8} {model.ram:13} {model.profile}"
            view.add_text(4 + index, 0, line, attr)

            if download and not download.done and not download.error:
                progress_col = len(line) + 2
                if progress_col + 10 < width:
                    bar_width = min(30, width - progress_col - 1)
                    bar = draw_progress_bar(download.fraction, bar_width)
                    view.add_text(4 + index, progress_col, bar)

        detail_top = 11
        selected_model = WHISPER_MODEL_CATALOG[selected]
        for offset, line in enumerate(model_detail_lines(selected_model, downloads.get(selected_model.key))):
            view.add_text(detail_top + offset, 0, line)

        screen.refresh()

        key = screen.getch()
        if key == -1:
            time.sleep(0.1)
            continue
        if key in (ord("q"), ord("Q"), 27):
            view.draw()
            return
        if key in (curses.KEY_UP, ord("k"), ord("K")):
            selected = (selected - 1) % len(WHISPER_MODEL_CATALOG)
            continue
        if key in (curses.KEY_DOWN, ord("j"), ord("J")):
            selected = (selected + 1) % len(WHISPER_MODEL_CATALOG)
            continue

        model = WHISPER_MODEL_CATALOG[selected]
        if key in (ord("\n"), curses.KEY_ENTER, ord("d"), ord("D")):
            start_download(model)
            continue
        if key in (ord("a"), ord("A")):
            try:
                activate_tui_model(view, model_state, model)
            except VoiceCliError as exc:
                view.add_log(str(exc))
        if key in (ord("x"), ord("X")):
            if model.key in download_threads and download_threads[model.key].is_alive():
                view.add_log(f"Cannot delete {model.display_name} while it is downloading.")
                continue
            try:
                delete_tui_model(view, model_state, model)
                downloads.pop(model.key, None)
            except VoiceCliError as exc:
                view.add_log(str(exc))


def run_language_manager(view: TuiView, args: argparse.Namespace) -> None:
    screen = view.screen
    selected = 0
    for index, option in enumerate(LANGUAGE_OPTIONS):
        if option.code == args.language:
            selected = index
            break

    while True:
        height, width = screen.getmaxyx()
        screen.erase()
        if height < 16 or width < 50:
            view.add_text(0, 0, "Language manager needs at least 50x16.", curses.A_BOLD)
            screen.refresh()
            time.sleep(0.1)
            key = screen.getch()
            if key in (ord("q"), ord("Q"), 27):
                return
            continue

        view.add_text(0, 0, "Whisper Language", curses.A_BOLD)
        view.add_text(1, 0, f"Active: {language_label(args.language)}")
        view.add_text(2, 0, "Controls: Up/Down select | Enter/A activate | Q close")

        for index, option in enumerate(LANGUAGE_OPTIONS):
            active = option.code == args.language
            marker = ">" if index == selected else " "
            state = "active" if active else "available"
            attr = curses.A_REVERSE if index == selected else 0
            view.add_text(4 + index, 0, f"{marker} {option.label:12} {option.code:5} {state}", attr)

        screen.refresh()
        key = screen.getch()
        if key == -1:
            time.sleep(0.1)
            continue
        if key in (ord("q"), ord("Q"), 27):
            view.draw()
            return
        if key in (curses.KEY_UP, ord("k"), ord("K")):
            selected = (selected - 1) % len(LANGUAGE_OPTIONS)
            continue
        if key in (curses.KEY_DOWN, ord("j"), ord("J")):
            selected = (selected + 1) % len(LANGUAGE_OPTIONS)
            continue
        if key in (ord("\n"), curses.KEY_ENTER, ord("a"), ord("A")):
            language = LANGUAGE_OPTIONS[selected].code
            args.language = language
            save_language(language)
            view.set_language(language)
            view.add_log(f"Language set to {language_label(language)}.")
            view.draw()
            return


def tui_worker(
    view: TuiView,
    phase: str,
    detail: Callable[[float], str],
    work: Callable[[], T],
    poll_interval: float = 0.05,
) -> T:
    result: list[T] = []
    error: list[BaseException] = []

    def target() -> None:
        try:
            result.append(work())
        except BaseException as exc:
            error.append(exc)

    thread = threading.Thread(target=target, daemon=True)
    thread.start()
    start = time.monotonic()

    while thread.is_alive():
        elapsed = time.monotonic() - start
        view.spin(phase, detail(elapsed))
        time.sleep(poll_interval)

    thread.join()
    if error:
        raise error[0]
    return result[0]


def capture_tui_audio_toggle(
    view: TuiView,
    args: argparse.Namespace,
    audio_path: Path,
    should_stop: Callable[[], bool],
) -> Path:
    view.set_phase("Starting recorder", f"backend={args.backend}")
    session = start_recording_session(audio_path, args.backend)
    view.add_log(f"Recording with {session.backend_name}. Press r to stop.")

    while True:
        elapsed = time.monotonic() - session.started_at
        view.spin("Recording", f"{elapsed:0.1f}s elapsed; press r to stop")

        key = view.screen.getch()
        if should_stop() or key in (ord("r"), ord("R"), ord("\n"), curses.KEY_ENTER):
            view.add_log("Stopping recording.")
            break
        if key in (ord("q"), ord("Q")):
            stop_recording(session.process)
            raise VoiceCliError("Recording cancelled.")
        if session.process.poll() is not None:
            view.add_log("Recorder stopped.")
            break

        time.sleep(0.05)

    return finish_recording_session(session)


def run_tui_pipeline(
    view: TuiView,
    args: argparse.Namespace,
    model_state: TuiModelState,
    whisper_cli: Path,
    llama_model: Path | None,
    llama_cli: Path | None,
    should_stop_recording: Callable[[], bool],
) -> str:
    whisper_model = model_state.active_path()
    if whisper_model is None or not whisper_model.is_file():
        raise VoiceCliError("No active Whisper model. Press M to download and activate one.")

    view.output = ""
    view.add_log("Starting pipeline.")
    view.add_log(f"Whisper model: {model_state.active_label()} ({whisper_model})")
    view.add_log(
        "Whisper decode: "
        f"language={args.language}, threads={args.whisper_threads}, "
        f"beam={args.whisper_beam_size}, best-of={args.whisper_best_of}, "
        f"fallback={'on' if args.whisper_fallback else 'off'}"
    )
    view.add_log(f"Refinement: {args.refine}")

    with tempfile.TemporaryDirectory(prefix="voice-tui-audio-") as temp_dir:
        audio_path = Path(temp_dir) / "recording.wav"
        if args.auto_run or args.once:
            seconds = args.seconds
            view.add_log(f"Recording {seconds:0.1f}s with backend={args.backend}.")
            tui_worker(
                view,
                "Recording",
                lambda elapsed: f"{max(0.0, seconds - elapsed):0.1f}s left",
                lambda: record_audio(audio_path, args.backend, seconds),
                poll_interval=0.1,
            )
        else:
            view.add_log(f"Waiting for toggle recording with backend={args.backend}.")
            capture_tui_audio_toggle(view, args, audio_path, should_stop_recording)

        if audio_path.exists():
            size_kb = audio_path.stat().st_size / 1024
            duration = audio_duration_seconds(audio_path)
            if duration is None:
                view.add_log(f"Captured {size_kb:0.1f} KiB WAV.")
            else:
                view.add_log(f"Captured {size_kb:0.1f} KiB WAV ({duration:0.1f}s).")

        transcribe_audio_path, trim_message = prepare_audio_for_transcription(audio_path, args, Path(temp_dir))
        if trim_message:
            view.add_log(trim_message)
        transcribe_start = time.monotonic()
        transcript = tui_worker(
            view,
            "Transcribing",
            lambda elapsed: f"whisper-cli running {elapsed:0.1f}s",
            lambda: transcribe_audio(
                transcribe_audio_path,
                whisper_model,
                whisper_cli,
                args.language,
                args.whisper_timeout,
                args.whisper_threads,
                args.whisper_beam_size,
                args.whisper_best_of,
                args.whisper_fallback,
                args.whisper_max_context,
            ),
        )
        transcribe_elapsed = time.monotonic() - transcribe_start
        transcribe_duration = audio_duration_seconds(transcribe_audio_path)
        if transcribe_duration:
            view.add_log(
                f"Transcription complete in {transcribe_elapsed:0.1f}s "
                f"({transcribe_elapsed / transcribe_duration:0.1f}x real time)."
            )
        else:
            view.add_log(f"Transcription complete in {transcribe_elapsed:0.1f}s.")

    if args.refine == "heuristic":
        view.set_phase("Refining", "heuristic cleanup")
        refine_start = time.monotonic()
        final_text = refine_text(transcript, args, llama_model, llama_cli)
        view.add_log(f"Refinement complete in {time.monotonic() - refine_start:0.1f}s.")
    elif args.refine == "llama":
        assert llama_model is not None
        assert llama_cli is not None
        refine_start = time.monotonic()
        final_text = tui_worker(
            view,
            "Refining",
            lambda elapsed: f"llama.cpp running {elapsed:0.1f}s",
            lambda: refine_text(transcript, args, llama_model, llama_cli),
        )
        view.add_log(f"Refinement complete in {time.monotonic() - refine_start:0.1f}s.")
    else:
        final_text = transcript

    view.set_output(final_text)
    view.set_phase("Complete", "Pipeline finished")
    try:
        paste_result = copy_and_maybe_paste(final_text, args)
        view.add_log(f"Copied final output to clipboard with {paste_result.clipboard_tool}.")
        if paste_result.paste_tool:
            view.add_log(f"Pasted final output with {paste_result.paste_tool}.")
        elif paste_result.paste_error:
            view.add_log(paste_result.paste_error)
    except VoiceCliError as exc:
        view.add_log(str(exc))

    view.add_log("Pipeline complete.")
    return final_text


def run_tui_screen(
    screen: curses.window,
    args: argparse.Namespace,
    model_state: TuiModelState,
    whisper_cli: Path,
    llama_model: Path | None,
    llama_cli: Path | None,
) -> str | None:
    view = TuiView(screen, model_state, args.language, args.hotkey)
    final_text: str | None = None
    should_run = args.auto_run or args.once
    hotkey_event = threading.Event()
    hotkey_manager: X11HotkeyManager | None = None

    if args.enable_hotkey:
        try:
            require_x11_session()
            hotkey_manager = X11HotkeyManager(args.hotkey, hotkey_event.set)
            hotkey_manager.start()
            view.add_log(f"Global hotkey active: {args.hotkey}")
        except VoiceCliError as exc:
            view.add_log(str(exc))

    def should_stop_recording() -> bool:
        if hotkey_event.is_set():
            hotkey_event.clear()
            return True
        return False

    try:
        while True:
            view.draw()

            if hotkey_event.is_set():
                hotkey_event.clear()
                should_run = True

            if should_run:
                should_run = False
                try:
                    final_text = run_tui_pipeline(
                        view,
                        args,
                        model_state,
                        whisper_cli,
                        llama_model,
                        llama_cli,
                        should_stop_recording,
                    )
                except BaseException as exc:
                    view.set_phase("Error", str(exc))
                    view.add_log(f"Error: {exc}")
                finally:
                    hotkey_event.clear()

                if args.once:
                    time.sleep(args.hold_seconds)
                    return final_text

            key = screen.getch()
            if key in (ord("q"), ord("Q")):
                return final_text
            if key in (ord("r"), ord("R"), ord("\n"), curses.KEY_ENTER):
                should_run = True
            if key in (ord("m"), ord("M")):
                run_model_manager(view, model_state)
            if key in (ord("l"), ord("L")):
                run_language_manager(view, args)
            if key in (ord("h"), ord("H")):
                if hotkey_manager:
                    hotkey_manager.stop()
                try:
                    view.set_phase("Record Shortcut", "Press the new global shortcut now.")
                    view.add_log("Recording next X11 key combination.")
                    new_hotkey = X11GlobalHotkey(args.hotkey).capture_next_hotkey()
                    args.hotkey = new_hotkey
                    save_hotkey(new_hotkey)
                    view.set_hotkey(new_hotkey)
                    if hotkey_manager:
                        hotkey_manager.update(new_hotkey)
                    else:
                        hotkey_manager = X11HotkeyManager(new_hotkey, hotkey_event.set)
                        hotkey_manager.start()
                    view.set_phase("Ready", "Idle")
                    view.add_log(f"Global hotkey updated: {new_hotkey}")
                except BaseException as exc:
                    if hotkey_manager:
                        hotkey_manager.start()
                    view.set_phase("Error", str(exc))
                    view.add_log(f"Hotkey capture failed: {exc}")

            time.sleep(0.05)
    finally:
        if hotkey_manager:
            hotkey_manager.stop()


def command_tui(args: argparse.Namespace) -> int:
    global STATUS_ENABLED
    if not sys.stdin.isatty():
        raise VoiceCliError("The TUI requires an interactive terminal.")
    if (args.auto_run or args.once) and args.seconds <= 0:
        raise VoiceCliError("--seconds must be greater than zero.")

    args.hotkey = resolve_hotkey(args.hotkey)
    args.language = resolve_language(args.language)
    model_state = initial_tui_model_state(args.whisper_model)
    whisper_cli = resolve_executable(args.whisper_cli, ("whisper-cli",))
    if args.refine == "llama" and not args.llama_model:
        raise VoiceCliError("--llama-model is required when --refine llama is selected.")
    llama_model = require_file(args.llama_model, "Llama model") if args.refine == "llama" else None
    llama_cli = resolve_executable(args.llama_cli, ("llama-cli", "llama-completion")) if args.refine == "llama" else None

    previous_status = STATUS_ENABLED
    STATUS_ENABLED = False
    try:
        curses.wrapper(run_tui_screen, args, model_state, whisper_cli, llama_model, llama_cli)
    finally:
        STATUS_ENABLED = previous_status
    return 0


class X11GlobalHotkey:
    def __init__(self, hotkey: str) -> None:
        lib_name = ctypes.util.find_library("X11")
        if not lib_name:
            raise VoiceCliError("libX11 is required for global hotkeys on X11.")

        self.lib = ctypes.CDLL(lib_name)
        self.configure_xlib()
        self.display = self.lib.XOpenDisplay(None)
        if not self.display:
            raise VoiceCliError("Could not open the X11 display. Global hotkeys require an X11 session.")

        self.root = self.lib.XDefaultRootWindow(self.display)
        self.hotkey = hotkey
        self.binding = self.parse_hotkey(hotkey)

    def configure_xlib(self) -> None:
        self.lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.lib.XOpenDisplay.restype = ctypes.c_void_p
        self.lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.lib.XDefaultRootWindow.restype = ctypes.c_ulong
        self.lib.XStringToKeysym.argtypes = [ctypes.c_char_p]
        self.lib.XStringToKeysym.restype = ctypes.c_ulong
        self.lib.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.lib.XKeysymToKeycode.restype = ctypes.c_ubyte
        self.lib.XKeycodeToKeysym.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int]
        self.lib.XKeycodeToKeysym.restype = ctypes.c_ulong
        self.lib.XKeysymToString.argtypes = [ctypes.c_ulong]
        self.lib.XKeysymToString.restype = ctypes.c_char_p
        self.lib.XGrabKey.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_uint,
            ctypes.c_ulong,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
        ]
        self.lib.XGrabKey.restype = ctypes.c_int
        self.lib.XUngrabKey.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong]
        self.lib.XUngrabKey.restype = ctypes.c_int
        self.lib.XGrabKeyboard.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_ulong,
        ]
        self.lib.XGrabKeyboard.restype = ctypes.c_int
        self.lib.XUngrabKeyboard.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.lib.XUngrabKeyboard.restype = ctypes.c_int
        self.lib.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.lib.XNextEvent.restype = ctypes.c_int
        self.lib.XPending.argtypes = [ctypes.c_void_p]
        self.lib.XPending.restype = ctypes.c_int
        self.lib.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.lib.XSync.restype = ctypes.c_int
        self.lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.lib.XCloseDisplay.restype = ctypes.c_int

    def parse_hotkey(self, hotkey: str) -> HotkeyBinding:
        parts = [part.strip() for part in re.split(r"[+,-]", hotkey) if part.strip()]
        if not parts:
            raise VoiceCliError("Hotkey cannot be empty.")

        modifiers = 0
        key_name = ""
        modifier_map = {
            "ctrl": X11_CONTROL_MASK,
            "control": X11_CONTROL_MASK,
            "alt": X11_MOD1_MASK,
            "mod1": X11_MOD1_MASK,
            "shift": X11_SHIFT_MASK,
            "super": X11_MOD4_MASK,
            "meta": X11_MOD4_MASK,
            "win": X11_MOD4_MASK,
            "mod4": X11_MOD4_MASK,
        }

        for part in parts:
            normalized = part.lower()
            if normalized in modifier_map:
                modifiers |= modifier_map[normalized]
            elif key_name:
                raise VoiceCliError(f"Only one non-modifier key is supported in a hotkey: {hotkey}")
            else:
                key_name = self.normalize_keysym_name(part)

        if not key_name:
            raise VoiceCliError(f"Hotkey is missing a key: {hotkey}")

        keysym = self.lib.XStringToKeysym(key_name.encode("ascii"))
        if keysym == 0:
            raise VoiceCliError(f"Unknown X11 key name: {key_name}")

        keycode = int(self.lib.XKeysymToKeycode(self.display, keysym))
        if keycode == 0:
            raise VoiceCliError(f"Could not map hotkey key to a keycode: {key_name}")

        return HotkeyBinding(key_name, keycode, modifiers)

    @staticmethod
    def normalize_keysym_name(value: str) -> str:
        key = value.strip()
        aliases = {
            " ": "space",
            "space": "space",
            "enter": "Return",
            "return": "Return",
            "esc": "Escape",
            "escape": "Escape",
            "tab": "Tab",
            "backspace": "BackSpace",
        }
        normalized = aliases.get(key.lower())
        if normalized:
            return normalized
        if len(key) == 1:
            return key
        return key[:1].upper() + key[1:]

    def grab(self) -> None:
        variants = [
            0,
            X11_LOCK_MASK,
            X11_MOD2_MASK,
            X11_LOCK_MASK | X11_MOD2_MASK,
        ]
        for variant in variants:
            self.lib.XGrabKey(
                self.display,
                self.binding.keycode,
                self.binding.modifiers | variant,
                self.root,
                0,
                X11_GRAB_MODE_ASYNC,
                X11_GRAB_MODE_ASYNC,
            )
        self.lib.XSync(self.display, 0)

    def ungrab(self) -> None:
        variants = [
            0,
            X11_LOCK_MASK,
            X11_MOD2_MASK,
            X11_LOCK_MASK | X11_MOD2_MASK,
        ]
        for variant in variants:
            self.lib.XUngrabKey(self.display, self.binding.keycode, self.binding.modifiers | variant, self.root)
        self.lib.XSync(self.display, 0)

    def capture_next_hotkey(self, stop_event: threading.Event | None = None) -> str:
        result = self.lib.XGrabKeyboard(
            self.display,
            self.root,
            0,
            X11_GRAB_MODE_ASYNC,
            X11_GRAB_MODE_ASYNC,
            X11_CURRENT_TIME,
        )
        if result != X11_GRAB_SUCCESS:
            raise VoiceCliError("Could not grab the keyboard to record a shortcut.")

        event = ctypes.create_string_buffer(192)
        try:
            while stop_event is None or not stop_event.is_set():
                if self.lib.XPending(self.display) == 0:
                    time.sleep(0.05)
                    continue

                self.lib.XNextEvent(self.display, event)
                event_type = ctypes.c_int.from_buffer(event).value
                if event_type != X11_KEY_PRESS:
                    continue

                key_event = XKeyEvent.from_buffer_copy(event)
                hotkey = self.event_to_hotkey(key_event)
                if hotkey:
                    return hotkey
        finally:
            self.lib.XUngrabKeyboard(self.display, X11_CURRENT_TIME)
            self.lib.XSync(self.display, 0)

        raise VoiceCliError("Shortcut capture was cancelled.")

    def event_to_hotkey(self, event: XKeyEvent) -> str:
        modifiers: list[str] = []
        if event.state & X11_CONTROL_MASK:
            modifiers.append("Ctrl")
        if event.state & X11_MOD1_MASK:
            modifiers.append("Alt")
        if event.state & X11_SHIFT_MASK:
            modifiers.append("Shift")
        if event.state & X11_MOD4_MASK:
            modifiers.append("Super")

        keysym = self.lib.XKeycodeToKeysym(self.display, event.keycode, 0)
        key_name_ptr = self.lib.XKeysymToString(keysym)
        if not key_name_ptr:
            return ""

        key_name = key_name_ptr.decode("ascii")
        if key_name in {"Control_L", "Control_R", "Alt_L", "Alt_R", "Shift_L", "Shift_R", "Super_L", "Super_R", "Meta_L", "Meta_R"}:
            return ""
        if len(key_name) == 1:
            key_name = key_name.upper()

        return "+".join([*modifiers, key_name])

    def listen(self, callback: Callable[[], None], stop_event: threading.Event | None = None) -> None:
        self.grab()
        event = ctypes.create_string_buffer(192)
        last_trigger = 0.0
        try:
            while stop_event is None or not stop_event.is_set():
                if self.lib.XPending(self.display) == 0:
                    time.sleep(0.05)
                    continue

                self.lib.XNextEvent(self.display, event)
                event_type = ctypes.c_int.from_buffer(event).value
                if event_type != X11_KEY_PRESS:
                    continue

                now = time.monotonic()
                if now - last_trigger < 0.35:
                    continue

                last_trigger = now
                callback()
        finally:
            self.ungrab()
            self.lib.XCloseDisplay(self.display)


class X11HotkeyManager:
    def __init__(self, hotkey: str, callback: Callable[[], None]) -> None:
        self.hotkey = hotkey
        self.callback = callback
        self.lock = threading.Lock()
        self.stop_event: threading.Event | None = None
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        with self.lock:
            if self.thread and self.thread.is_alive():
                return

            self.stop_event = threading.Event()
            self.thread = threading.Thread(target=self.run_listener, args=(self.hotkey, self.stop_event), daemon=True)
            self.thread.start()

    def stop(self) -> None:
        with self.lock:
            stop_event = self.stop_event
            thread = self.thread
            self.stop_event = None
            self.thread = None

        if stop_event:
            stop_event.set()
        if thread and thread.is_alive():
            thread.join(timeout=1.5)

    def update(self, hotkey: str) -> None:
        self.stop()
        self.hotkey = hotkey
        self.start()

    def run_listener(self, hotkey: str, stop_event: threading.Event) -> None:
        try:
            X11GlobalHotkey(hotkey).listen(self.callback, stop_event)
        except BaseException as exc:
            print(f"Voice: global hotkey listener stopped: {exc}", file=sys.stderr, flush=True)


def require_x11_session() -> None:
    session_type = os.environ.get("XDG_SESSION_TYPE", "").lower()
    if session_type == "wayland" or os.environ.get("WAYLAND_DISPLAY"):
        raise VoiceCliError(
            "Wayland does not allow arbitrary global keyboard grabs. "
            "Use an X11 Cinnamon session or bind a desktop shortcut to a Voice command."
        )
    if not os.environ.get("DISPLAY"):
        raise VoiceCliError("DISPLAY is not set. Global hotkeys require an X11 display.")


def run_finished_audio_pipeline(
    audio_path: Path,
    args: argparse.Namespace,
    whisper_model: Path,
    whisper_cli: Path,
    llama_model: Path | None,
    llama_cli: Path | None,
) -> str:
    duration = audio_duration_seconds(audio_path)
    if duration is not None:
        print(f"Voice: captured {duration:0.1f}s of audio.", file=sys.stderr, flush=True)
    transcribe_audio_path, trim_message = prepare_audio_for_transcription(audio_path, args)
    if trim_message:
        print(f"Voice: {trim_message}", file=sys.stderr, flush=True)
    print("Voice: transcribing...", file=sys.stderr, flush=True)
    transcribe_start = time.monotonic()
    transcript = transcribe_audio(
        transcribe_audio_path,
        whisper_model,
        whisper_cli,
        args.language,
        args.whisper_timeout,
        args.whisper_threads,
        args.whisper_beam_size,
        args.whisper_best_of,
        args.whisper_fallback,
        args.whisper_max_context,
    )
    transcribe_elapsed = time.monotonic() - transcribe_start
    transcribe_duration = audio_duration_seconds(transcribe_audio_path)
    if transcribe_duration:
        print(
            f"Voice: transcription completed in {transcribe_elapsed:0.1f}s "
            f"({transcribe_elapsed / transcribe_duration:0.1f}x real time).",
            file=sys.stderr,
            flush=True,
        )
    else:
        print(f"Voice: transcription completed in {transcribe_elapsed:0.1f}s.", file=sys.stderr, flush=True)
    refine_start = time.monotonic()
    final_text = refine_text(transcript, args, llama_model, llama_cli)
    print(f"Voice: refinement completed in {time.monotonic() - refine_start:0.1f}s.", file=sys.stderr, flush=True)
    paste_result = copy_and_maybe_paste(final_text, args)
    print(f"Voice: copied result to clipboard with {paste_result.clipboard_tool}.", file=sys.stderr, flush=True)
    if paste_result.paste_tool:
        print(f"Voice: pasted result with {paste_result.paste_tool}.", file=sys.stderr, flush=True)
    elif paste_result.paste_error:
        print(f"Voice: {paste_result.paste_error}", file=sys.stderr, flush=True)
    print(final_text, flush=True)
    return final_text


def command_hotkey(args: argparse.Namespace) -> int:
    require_x11_session()
    args.hotkey = resolve_hotkey(args.hotkey)
    args.language = resolve_language(args.language)
    whisper_model = resolve_whisper_model(args.whisper_model)
    whisper_cli = resolve_executable(args.whisper_cli, ("whisper-cli",))
    if args.refine == "llama" and not args.llama_model:
        raise VoiceCliError("--llama-model is required when --refine llama is selected.")
    llama_model = require_file(args.llama_model, "Llama model") if args.refine == "llama" else None
    llama_cli = resolve_executable(args.llama_cli, ("llama-cli", "llama-completion")) if args.refine == "llama" else None

    lock = threading.Lock()
    session: RecordingSession | None = None
    temp_dir: tempfile.TemporaryDirectory[str] | None = None
    processing = False

    def finish_in_background(active_session: RecordingSession, active_temp_dir: tempfile.TemporaryDirectory[str]) -> None:
        nonlocal processing
        try:
            audio_path = finish_recording_session(active_session)
            run_finished_audio_pipeline(audio_path, args, whisper_model, whisper_cli, llama_model, llama_cli)
        except BaseException as exc:
            print(f"Voice: {exc}", file=sys.stderr, flush=True)
        finally:
            active_temp_dir.cleanup()
            with lock:
                processing = False

    def toggle_recording() -> None:
        nonlocal session, temp_dir, processing

        with lock:
            if processing:
                print("Voice: still processing; hotkey ignored.", file=sys.stderr, flush=True)
                return

            if session is None:
                temp_dir = tempfile.TemporaryDirectory(prefix="voice-hotkey-audio-")
                audio_path = Path(temp_dir.name) / "recording.wav"
                try:
                    session = start_recording_session(audio_path, args.backend)
                except BaseException:
                    temp_dir.cleanup()
                    temp_dir = None
                    raise
                print(
                    f"Voice: recording started with {session.backend_name}; press {args.hotkey} again to stop.",
                    file=sys.stderr,
                    flush=True,
                )
                return

            active_session = session
            assert temp_dir is not None
            active_temp_dir = temp_dir
            session = None
            temp_dir = None
            processing = True

        print("Voice: recording stopped; processing...", file=sys.stderr, flush=True)
        threading.Thread(
            target=finish_in_background,
            args=(active_session, active_temp_dir),
            daemon=True,
        ).start()

    hotkey = X11GlobalHotkey(args.hotkey)
    stop_event = threading.Event()

    previous_sigint = signal.getsignal(signal.SIGINT)
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def request_stop(signum: int, _frame: object) -> None:
        stop_event.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    print(
        f"Voice: listening for {args.hotkey} on X11. Press Ctrl+C to stop the daemon.",
        file=sys.stderr,
        flush=True,
    )
    try:
        hotkey.listen(toggle_recording, stop_event)
    finally:
        signal.signal(signal.SIGINT, previous_sigint)
        signal.signal(signal.SIGTERM, previous_sigterm)
        print("Voice: hotkey daemon stopped.", file=sys.stderr, flush=True)
    return 0


def add_common_audio_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--backend", choices=("auto", "pw-record", "arecord", "ffmpeg"), default="auto")
    parser.add_argument("--seconds", type=float, help="Record for a fixed number of seconds. Omit for press-Enter-to-stop mode.")


def add_whisper_decode_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--whisper-threads",
        type=int,
        default=default_whisper_threads(),
        help="whisper.cpp compute threads. Defaults to min(8, CPU count).",
    )
    parser.add_argument(
        "--whisper-beam-size",
        type=int,
        default=1,
        help="Beam size for whisper.cpp decoding. Lower is faster; upstream default is 5.",
    )
    parser.add_argument(
        "--whisper-best-of",
        type=int,
        default=1,
        help="Best-of candidates for whisper.cpp decoding. Lower is faster; upstream default is 5.",
    )
    parser.add_argument(
        "--whisper-fallback",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Allow whisper.cpp temperature fallback retries. Disabled by default for faster dictation.",
    )
    parser.add_argument(
        "--whisper-max-context",
        type=int,
        default=0,
        help="Maximum context tokens for whisper.cpp. Defaults to 0 for short one-shot dictation.",
    )


def add_audio_processing_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--trim-silence",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Trim leading and trailing silence with ffmpeg before transcription.",
    )
    parser.add_argument(
        "--trim-silence-ms",
        type=int,
        default=250,
        help="Minimum silence duration for trimming, in milliseconds.",
    )
    parser.add_argument(
        "--trim-silence-threshold",
        default="-45dB",
        help="ffmpeg silenceremove threshold for trimming.",
    )
    parser.add_argument(
        "--min-speech-seconds",
        type=float,
        default=0.25,
        help="Skip Whisper when trimmed audio is shorter than this many seconds.",
    )


def add_paste_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--auto-paste",
        dest="auto_paste",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Paste the final clipboard text into the focused window after transcription.",
    )
    parser.add_argument(
        "--paste-delay-ms",
        type=int,
        default=120,
        help="Delay before sending the paste shortcut, in milliseconds.",
    )
    parser.add_argument(
        "--paste-tool",
        choices=("auto", "xdotool", "wtype"),
        default="auto",
        help="Keyboard injection backend for auto-paste.",
    )
    parser.add_argument(
        "--paste-key",
        choices=("auto", "ctrl+v", "ctrl+shift+v", "shift+insert"),
        default="auto",
        help="Key combo used to paste. auto detects terminal vs GUI via WM_CLASS on X11 (ctrl+shift+v fallback).",
    )


def add_quiet_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("-q", "--quiet", action="store_true", help="Disable terminal status output on stderr.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="voice",
        description="Terminal MVP for the Voice Linux dictation pipeline.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor", help="Check Linux runtime dependencies.")
    add_quiet_arg(doctor)
    doctor.add_argument("--whisper-cli")
    doctor.add_argument("--llama-cli")
    doctor.add_argument("--whisper-model")
    doctor.add_argument("--llama-model")
    doctor.set_defaults(func=command_doctor)

    record = subparsers.add_parser("record", help="Capture 16 kHz mono WAV audio.")
    add_quiet_arg(record)
    record.add_argument("--out", required=True)
    add_common_audio_args(record)
    record.set_defaults(func=command_record)

    transcribe = subparsers.add_parser("transcribe", help="Run whisper.cpp over a WAV file.")
    add_quiet_arg(transcribe)
    transcribe.add_argument("--audio", required=True)
    transcribe.add_argument("--model", required=True)
    transcribe.add_argument("--whisper-cli")
    transcribe.add_argument("--language", help="Whisper language code. Defaults to saved setting, initially en.")
    transcribe.add_argument("--timeout", type=float)
    add_whisper_decode_args(transcribe)
    add_audio_processing_args(transcribe)
    transcribe.set_defaults(func=command_transcribe)

    refine = subparsers.add_parser("refine", help="Clean up transcript text.")
    add_quiet_arg(refine)
    refine.add_argument("--backend", choices=("none", "heuristic", "llama"), default="heuristic")
    refine.add_argument("--text")
    refine.add_argument("--model", help="GGUF model path for --backend llama.")
    refine.add_argument("--llama-cli")
    refine.add_argument("--profile", choices=("literal", "balanced", "polished"), default="balanced")
    refine.add_argument("--timeout", type=float, default=LLAMA_TIMEOUT_SECONDS)
    refine.set_defaults(func=command_refine)

    run = subparsers.add_parser("run", help="Record, transcribe, optionally refine, and print final text.")
    add_quiet_arg(run)
    run.add_argument("--whisper-model", help="Whisper model path. Defaults to the active downloaded model.")
    run.add_argument("--whisper-cli")
    run.add_argument("--language", help="Whisper language code. Defaults to saved setting, initially en.")
    run.add_argument("--whisper-timeout", type=float)
    add_whisper_decode_args(run)
    run.add_argument("--refine", choices=("none", "heuristic", "llama"), default="heuristic")
    run.add_argument("--llama-model", help="GGUF model path for --refine llama.")
    run.add_argument("--llama-cli")
    run.add_argument("--profile", choices=("literal", "balanced", "polished"), default="balanced")
    run.add_argument("--llama-timeout", type=float, default=LLAMA_TIMEOUT_SECONDS)
    add_common_audio_args(run)
    add_audio_processing_args(run)
    add_paste_args(run)
    run.set_defaults(func=command_run)

    tui = subparsers.add_parser("tui", help="Run the terminal UI MVP.")
    tui.add_argument("--whisper-model", help="Whisper model path. Defaults to the active downloaded model.")
    tui.add_argument("--whisper-cli")
    tui.add_argument("--language", help="Whisper language code. Defaults to saved setting, initially en.")
    tui.add_argument("--whisper-timeout", type=float)
    add_whisper_decode_args(tui)
    tui.add_argument("--refine", choices=("none", "heuristic", "llama"), default="heuristic")
    tui.add_argument("--llama-model", help="GGUF model path for --refine llama.")
    tui.add_argument("--llama-cli")
    tui.add_argument("--profile", choices=("literal", "balanced", "polished"), default="balanced")
    tui.add_argument("--llama-timeout", type=float, default=LLAMA_TIMEOUT_SECONDS)
    tui.add_argument("--backend", choices=("auto", "pw-record", "arecord", "ffmpeg"), default="auto")
    tui.add_argument("--seconds", type=float, default=5.0, help="Recording duration for --auto-run or --once.")
    tui.add_argument("--auto-run", action="store_true", help="Start with a timed recording immediately.")
    tui.add_argument("--once", action="store_true", help="Run once and exit after --hold-seconds.")
    tui.add_argument("--hold-seconds", type=float, default=2.0)
    tui.add_argument("--hotkey", help="Override the persisted X11 global hotkey for this launch.")
    tui.add_argument("--disable-hotkey", dest="enable_hotkey", action="store_false")
    add_audio_processing_args(tui)
    add_paste_args(tui)
    tui.set_defaults(func=command_tui, enable_hotkey=True)

    hotkey = subparsers.add_parser("hotkey", help="Run the X11 global hotkey daemon.")
    hotkey.add_argument("--hotkey", help="Override the persisted X11 global hotkey for this launch.")
    hotkey.add_argument("--whisper-model", help="Whisper model path. Defaults to the active downloaded model.")
    hotkey.add_argument("--whisper-cli")
    hotkey.add_argument("--language", help="Whisper language code. Defaults to saved setting, initially en.")
    hotkey.add_argument("--whisper-timeout", type=float)
    add_whisper_decode_args(hotkey)
    hotkey.add_argument("--refine", choices=("none", "heuristic", "llama"), default="heuristic")
    hotkey.add_argument("--llama-model", help="GGUF model path for --refine llama.")
    hotkey.add_argument("--llama-cli")
    hotkey.add_argument("--profile", choices=("literal", "balanced", "polished"), default="balanced")
    hotkey.add_argument("--llama-timeout", type=float, default=LLAMA_TIMEOUT_SECONDS)
    hotkey.add_argument("--backend", choices=("auto", "pw-record", "arecord", "ffmpeg"), default="auto")
    add_audio_processing_args(hotkey)
    add_paste_args(hotkey)
    hotkey.set_defaults(func=command_hotkey)

    return parser


def main(argv: Iterable[str] | None = None) -> int:
    global STATUS_ENABLED
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    STATUS_ENABLED = not getattr(args, "quiet", False)

    try:
        return args.func(args)
    except VoiceCliError as exc:
        print(f"voice: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Local-first dictation app. Two separate implementations sharing the same external tool pipeline (whisper.cpp + llama.cpp subprocesses):

- **macOS**: SwiftUI menu-bar app (`Sources/Voice/`) — global hotkey → record WAV → whisper-cli → optional llama-cli refine → CGEvent text insertion
- **Linux**: Python 3 curses TUI + X11 hotkey daemon (`tools/voice-cli/voice.py`) — same pipeline via shell subprocesses, xdotool/wtype for paste

## Build & Test

**macOS**
```bash
swift build          # compile
swift run            # launch menu-bar app
```

Manual test: run `swift build`, exercise affected menu-bar or Settings flows.

**Linux**
```bash
# Full setup (detects GPU: auto, cuda, vulkan, cpu)
bash tools/voice-cli/install.sh
bash tools/voice-cli/install.sh --update   # rebuild whisper.cpp

# Smoke tests after changes
python3 tools/voice-cli/voice.py doctor    # check all deps
python3 tools/voice-cli/voice.py record --out /tmp/v.wav --seconds 3
python3 tools/voice-cli/voice.py transcribe --audio /tmp/v.wav
python3 tools/voice-cli/voice.py run --seconds 3 --refine heuristic
python3 tools/voice-cli/voice.py tui --once --hold-seconds 1 --seconds 3

voice   # launch TUI (after install to PATH)
```

No automated test suite. Manual verification required before submitting.

## Architecture

### macOS State Machine

`AppCoordinator` owns `DictationState` (`idle → listening → transcribing → refining → inserting → completed/error`) and orchestrates:

```
Hotkey → AudioCaptureService (16kHz mono WAV, AVAudioRecorder)
       → WhisperCppTranscriber (whisper-cli subprocess via ShellCommandRunner)
       → HeuristicTextRefiner | LlamaCppTextRefiner
       → TextInsertionService (CGEvent)
```

Services are protocol-backed (`SpeechTranscriber`, `TextRefining`) — swap implementations without touching the coordinator. `PermissionService` gates startup (microphone + AXIsProcessTrusted). `ModelLibrary` handles download + activation of Whisper/Llama models. `OverlayPanelController` shows a floating NSPanel during recording/transcription.

`AppSettings` holds all user config: model paths, language, `RecordingTriggerMode` (hold vs toggle), `TextInsertionMode` (pasteboard vs keystrokes), `RefinementBackend`, `RefinementProfile`.

### Linux Single-File Design

`voice.py` (3,100+ lines) is intentionally one file for easy distribution. Subcommands: `doctor`, `record`, `transcribe`, `run`, `tui`, `hotkey`.

X11 hotkey daemon uses `XGrabKey` via `ctypes.libX11` — no Python X11 bindings needed. Audio capture prefers `pw-record` (PipeWire) → `arecord` (ALSA) → `ffmpeg` fallback. Text insertion: `xdotool` (X11) or `wtype` (Wayland).

Config stored at XDG paths: `~/.config/voice/config.json`, models at `~/.local/share/voice/models/`.

Key environment variables: `VOICE_WHISPER_MODEL`, `VOICE_LANGUAGE`, `VOICE_REFINE` (none/heuristic/llama), `VOICE_SECONDS`, `VOICE_AUTO_PASTE`, `VOICE_HOTKEY`.

## Coding Style

- Swift: 4-space indent, Swift 6 strict concurrency, `PascalCase` types, `camelCase` members. Services layer owns all external process/audio/model logic; Views stay thin.
- Python: stdlib-first, `snake_case` functions, type hints where useful, user-facing errors via `VoiceCliError`.

## Important Constraints

- Never commit model files (`.bin`, `.gguf`), recorded audio, or machine-specific paths.
- Model locations must stay configurable (Settings UI / CLI flags / `VOICE_*` env vars).
- Both platforms shell out to whisper-cli/llama-cli binaries — they are not linked as libraries.

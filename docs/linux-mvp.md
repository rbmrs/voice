# Linux Terminal MVP

This branch isolates the Linux port behind a terminal-first CLI while leaving the
existing macOS SwiftUI menu-bar app intact.

## Goal

Validate the local dictation pipeline on Linux Mint before investing in a GUI:

1. Capture microphone input as 16 kHz mono PCM WAV.
2. Transcribe the WAV with `whisper.cpp`.
3. Optionally refine the transcript with a heuristic pass or `llama.cpp`.
4. Print final text to stdout.

Desktop text insertion, global hotkeys, settings windows, and overlays are out
of scope for the first MVP.

## Current macOS Boundaries

- `SwiftUI`, `AppKit`, `NSPanel`, and menu-bar lifecycle stay macOS-only.
- `AVFoundation` audio recording is replaced by Linux recorder commands.
- `KeyboardShortcuts` global hotkeys are replaced by explicit CLI commands.
- `ApplicationServices`, `AXIsProcessTrusted`, `CGEvent`, and `NSPasteboard`
  text insertion are replaced by stdout for MVP.
- macOS Application Support model paths are replaced by XDG paths:
  `~/.local/share/voice/models`.

The portable behavior to preserve is the external process pipeline:
`whisper-cli` for transcription and `llama-cli` / `llama-completion` for
refinement.

## CLI

The MVP CLI lives at:

```bash
tools/voice-cli/voice.py
```

Run a dependency check:

```bash
python3 tools/voice-cli/voice.py doctor
```

Record audio:

```bash
python3 tools/voice-cli/voice.py record --out /tmp/voice.wav --seconds 5
```

Transcribe an existing WAV:

```bash
python3 tools/voice-cli/voice.py transcribe \
  --audio /tmp/voice.wav \
  --model ~/.local/share/voice/models/whisper/ggml-base.en.bin
```

Run the end-to-end pipeline with heuristic cleanup:

```bash
python3 tools/voice-cli/voice.py run \
  --seconds 5 \
  --whisper-model ~/.local/share/voice/models/whisper/ggml-base.en.bin \
  --refine heuristic
```

The CLI writes live phase/status output to stderr when attached to a terminal
and keeps stdout reserved for the final transcript. Use `--quiet` on any
subcommand to disable status output:

```bash
python3 tools/voice-cli/voice.py run --quiet \
  --seconds 5 \
  --whisper-model ~/.local/share/voice/models/whisper/ggml-base.en.bin \
  --refine heuristic
```

Run the end-to-end pipeline with `llama.cpp` cleanup:

```bash
python3 tools/voice-cli/voice.py run \
  --seconds 5 \
  --whisper-model ~/.local/share/voice/models/whisper/ggml-base.en.bin \
  --refine llama \
  --llama-model ~/.local/share/voice/models/llama/model.gguf
```

Launch the curses-based TUI MVP:

```bash
voice
```

The one-word launcher uses these defaults:

```bash
VOICE_WHISPER_MODEL=... # optional override; otherwise use the active TUI model
VOICE_LANGUAGE=en
VOICE_REFINE=heuristic
VOICE_WHISPER_TIMEOUT=120
VOICE_WHISPER_THREADS=4
VOICE_WHISPER_BEAM_SIZE=1
VOICE_WHISPER_BEST_OF=1
VOICE_WHISPER_FALLBACK=0
VOICE_WHISPER_MAX_CONTEXT=0
VOICE_TRIM_SILENCE=0
VOICE_TRIM_SILENCE_MS=250
VOICE_TRIM_SILENCE_THRESHOLD=-45dB
VOICE_MIN_SPEECH_SECONDS=0.25
VOICE_SECONDS=5    # only used by --auto-run or --once
VOICE_AUTO_PASTE=1
VOICE_PASTE_DELAY_MS=120
VOICE_PASTE_TOOL=auto # auto, xdotool, or wtype
VOICE_HOTKEY=Ctrl+Alt+space # optional override; otherwise use saved shortcut
```

Override defaults with environment variables or pass additional TUI flags:

```bash
VOICE_REFINE=none voice
VOICE_SECONDS=8 voice --auto-run
VOICE_LANGUAGE=en voice
```

The CLI uses English transcription by default and saves language changes made
from the TUI language picker. Press `L` in the TUI to choose another language
or `Auto-detect`; pass `--language auto` or set `VOICE_LANGUAGE=auto` when you
need detection. It also uses fast dictation decode defaults: `--whisper-beam-size 1`,
`--whisper-best-of 1`, and `--no-whisper-fallback`, with threads set to
`min(8, CPU count)` and `--whisper-max-context 0`. Before transcription, the
pipeline trims leading and trailing silence with `ffmpeg` and skips Whisper if
the trimmed audio is too short to contain speech. Medium and Large models can
still be slow on CPU-only Mint systems; use Large v3 Turbo if available,
otherwise Small or Base, and keep `VOICE_LANGUAGE=en` if you do not need
language auto-detection.

The TUI opens at a ready screen by default. Press `r` to start recording, press
`r` again to stop, then wait for transcription and refinement. Press `M` to
open the Whisper model manager. The manager lists Tiny, Base, Small, Medium,
Large v3 Turbo, and Large v3 models from the `ggerganov/whisper.cpp` Hugging
Face repository, shows size, RAM, and speed/accuracy profile, downloads to
`~/.local/share/voice/models/whisper`, and saves the active model in
`~/.config/voice/config.json`. Press `Enter` or `D` in the manager to download
the selected model, press `A` to activate a downloaded model, and press `X` to
delete a downloaded model.

The current global hotkey is shown in the dashboard and can trigger the same
start/stop cycle even when the terminal is not focused. Press `H` to enter
shortcut recording mode, then press the next key combination, such as
`Super+Shift+R`, to update the global binding in the running app. The shortcut
is saved to `~/.config/voice/config.json` and reused on the next launch. The
final output is copied to the clipboard when `wl-copy`, `xclip`, `xsel`, or an
OSC 52-capable terminal is available. Auto-paste is enabled by default: on Linux
Mint Cinnamon/X11 it sends `Ctrl+V` with `xdotool` when installed, otherwise it
uses a native XTest fallback through `libX11`/`libXtst`; on Wayland it can use
`wtype` when available. Use `--no-auto-paste` or `VOICE_AUTO_PASTE=0` to only
copy. Press `Q` to quit. For a one-shot timed smoke test that exits
automatically using the active model:

```bash
python3 tools/voice-cli/voice.py tui --once --hold-seconds 1 \
  --seconds 5 \
  --refine heuristic
```

Run the X11 global hotkey daemon:

```bash
voice hotkey
```

Default hotkey:

```bash
Ctrl+Alt+space
```

Press the hotkey once to start recording. Press it again to stop recording,
transcribe, refine, copy the final output to the clipboard, and paste into the
focused window. The daemon keeps listening after each dictation.

Use another shortcut if Cinnamon already owns the default:

```bash
voice hotkey --hotkey Ctrl+Alt+F9
```

The hotkey backend uses X11 `XGrabKey` through `libX11`, so it does not need
root access or input-device permissions and does not observe normal typing. The
TUI shortcut recorder temporarily uses `XGrabKeyboard` only while the app is in
the `Record Shortcut` state. This is the intended path for Linux Mint Cinnamon
on X11. Wayland sessions do not permit arbitrary global keyboard grabs; use an
X11 Cinnamon session or bind a desktop shortcut to a Voice command there.

## Automated Setup

The recommended path is the install script:

```bash
bash tools/voice-cli/install.sh
```

This installs system packages, auto-detects your GPU (NVIDIA CUDA, Vulkan, or CPU+OpenBLAS),
builds `whisper-cli` from source, and symlinks the `voice` command to `~/.local/bin`.
Re-run with `--update` to pull the latest whisper.cpp and rebuild.

After setup, launch the TUI and press `M` to download a Whisper model, then `R` to record.

---

## Manual / Advanced Setup

### Linux Mint base packages

```bash
sudo apt update
sudo apt install -y \
  git build-essential cmake ninja-build pkg-config ccache curl wget \
  ffmpeg sox xclip xdotool \
  libopenblas-dev libssl-dev \
  pipewire pipewire-pulse pulseaudio-utils alsa-utils \
  libasound2-dev portaudio19-dev libsdl2-dev
```

Vulkan path, recommended first for AMD GPUs and Steam Deck-class hardware:

```bash
sudo apt install -y libvulkan-dev vulkan-tools glslc
vulkaninfo
```

NVIDIA CUDA path:

```bash
nvidia-smi
nvcc --version
```

Install CUDA from NVIDIA's supported Ubuntu-compatible repository for the Mint
base release in use.

## Building Inference Tools

CPU baseline:

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

CUDA:

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON
cmake --build build -j
```

Vulkan:

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=1
cmake --build build -j
```

OpenBLAS CPU acceleration:

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS
cmake --build build -j
```

## Roadmap

Stage 1: Dependency validation

- Keep `voice doctor` as the first command to run on new Linux machines.
- Verify `whisper-cli`, one recorder backend, model paths, and optional GPU
  tools.

Stage 2: File transcription

- Validate `voice transcribe` against known-good WAV fixtures.
- Match the macOS app's Whisper options: no timestamps, text output, explicit
  language selection.

Stage 3: Audio capture

- Prefer `pw-record`.
- Fall back to `arecord`.
- Use `ffmpeg` when PulseAudio/PipeWire device handling is more reliable.

Stage 4: Refinement

- Use the heuristic refiner by default.
- Use `llama-completion` automatically when it exists beside `llama-cli`.
- Keep the LLM timeout bounded to avoid hung terminal sessions.

Stage 5: TUI

- TUI supports toggle recording: `R` starts, `R` stops.
- Keep the TUI state model simple: ready, recording, transcribing, refining,
  complete, and error.

Stage 6: Desktop integration

- Clipboard copy is wired through `wl-copy`, `xclip`, `xsel`, or OSC 52.
- Auto-paste sends the clipboard with `xdotool` or native XTest on X11, or
  `wtype` on Wayland, with a configurable delay before the paste shortcut.

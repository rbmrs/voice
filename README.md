<p align="center">
  <img src="voice_logo.png" alt="Voice logo" width="30%">
</p>

# Voice

`Voice` is a local-first dictation app built around `whisper.cpp` and `llama.cpp`. It follows the workflow of tools like SuperWhisper or Wispr Flow while keeping transcription and optional cleanup on-device.

- **macOS** — native menu-bar SwiftUI app
- **Linux** — terminal-first curses TUI under `tools/voice-cli`

## Features

### macOS

- Menu-bar-only SwiftUI app with a settings window
- Global dictation shortcut via `KeyboardShortcuts`
- Local microphone capture to 16 kHz mono WAV through `AVAudioRecorder`
- Local transcription with `whisper.cpp`
- Optional second-pass cleanup with a built-in heuristic refiner or a local `llama.cpp` GGUF model
- System-wide text insertion into the frontmost app via `CGEvent`
- Permission checks and quick-open actions for Microphone and Accessibility
- Floating overlay feedback for listening, transcribing, refining, inserting, completion, and errors
- Managed model downloads with in-app progress, activation, and deletion

### Linux

- Curses TUI launchable with the `voice` command
- Toggle recording with `R` — start, stop, transcribe, refine in one keystroke
- X11 global hotkey daemon (`voice hotkey`) for hands-free trigger from any window
- Auto-paste into the focused window via `xdotool` (X11) or `wtype` (Wayland)
- Clipboard copy through `wl-copy`, `xclip`, `xsel`, or OSC 52
- In-TUI Whisper model manager — browse, download, activate, and delete models
- Configurable via environment variables (`VOICE_*`) or `~/.config/voice/config.json`

### Shared

- Local transcription with `whisper.cpp`
- Optional heuristic refiner (no extra model required)
- Optional `llama.cpp` second-pass cleanup with any GGUF model

## Setup

### macOS

Install the upstream CLIs:

```bash
brew install whisper-cpp llama.cpp
```

Typical Apple Silicon locations:

- `whisper-cli`: `/opt/homebrew/bin/whisper-cli`
- `llama-cli`: `/opt/homebrew/bin/llama-cli`
- `llama-completion`: `/opt/homebrew/bin/llama-completion`

Then build and run:

```bash
swift build
swift run
```

`swift run` launches a menu-bar app, so the terminal stays attached while the app is running. Quit from the menu bar or press `Ctrl+C` in the terminal.

### Linux

```bash
bash tools/voice-cli/install.sh
```

Installs system packages through `apt` or `dnf`, builds `whisper.cpp` with GPU
acceleration if available, and wires the `voice` command to `~/.local/bin`.
Then:

```bash
voice        # launch the TUI
```

See `docs/linux-mvp.md` for GPU options, manual steps, and troubleshooting.

## First-run flow

### macOS

1. Launch the app with `swift run`.
2. Open the menu bar item and then open `Settings`.
3. Grant Microphone and Accessibility access.
4. Resolve `whisper-cli` from Settings if needed.
5. Download a Whisper model from the built-in catalog, or browse to a local `.bin` file.
6. Optionally enable second-pass cleanup and configure `llama.cpp`.

### Linux

1. Run `python3 tools/voice-cli/voice.py doctor` to check runtime dependencies.
2. Launch the TUI with `voice`.
3. Press `M` to open the model manager and download a Whisper model.
4. Press `R` to start recording, `R` again to stop.

## Model management

### macOS

Models are stored in:

- `~/Library/Application Support/Voice/Models/Whisper`
- `~/Library/Application Support/Voice/Models/Llama`

Settings supports downloading curated models with live percentage progress, browsing to custom local `.bin` or `.gguf` files, switching between downloaded models, and deleting models that are not active. Downloads do not automatically switch the active model — activate with `Use`.

### Linux

Models are stored in:

- `~/.local/share/voice/models/whisper`
- `~/.local/share/voice/models/llama`

The in-TUI model manager (press `M`) lists Tiny, Base, Small, Medium, Large v3 Turbo, and Large v3 models from the `ggerganov/whisper.cpp` Hugging Face repository. Press `D` to download, `A` to activate, and `X` to delete. The active model is saved to `~/.config/voice/config.json`.

## Refinement behavior

The second pass is optional on both platforms.

- `Heuristic` mode works without any extra model.
- `llama.cpp` mode requires a GGUF model and a local `llama.cpp` install.

On macOS, when the configured executable is `llama-cli`, the app automatically uses the sibling `llama-completion` binary for non-interactive cleanup if it exists, avoiding chat-mode hangs in recent Homebrew installs.

On Linux, `llama-completion` is used automatically when it exists beside `llama-cli`. Manual local GGUF files work for custom Llama 3.2 or Mistral setups on both platforms.

## Notes

- This project is intentionally packaged as a SwiftPM macOS app so it can build in environments that only have Xcode Command Line Tools installed.
- For a distributable `.app` bundle, wrap the package in an Xcode app target and add `NSMicrophoneUsageDescription` to the generated app's `Info.plist`.
- The current transcription path uses upstream `whisper.cpp` CLI arguments such as `--model`, `--file`, `--output-txt`, `--output-file`, `--no-prints`, and `--no-timestamps`.
- On Linux, the global hotkey uses X11 `XGrabKey` and does not require root access. Wayland sessions do not support arbitrary global keyboard grabs — use an X11 session or bind a desktop shortcut to a `voice` command instead.

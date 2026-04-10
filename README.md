<p align="center">
  <img src="voice_logo.png" alt="Voice logo" width="30%">
</p>

# Voice

`Voice` is a native macOS menu-bar dictation app focused on local-first speech-to-text. It follows the workflow of tools like SuperWhisper or Wispr Flow while keeping transcription and optional cleanup on-device through `whisper.cpp` and `llama.cpp`.

## Features

- Menu-bar-only SwiftUI app with a settings window
- Global dictation shortcut via `KeyboardShortcuts`
- Local microphone capture to 16 kHz mono WAV through `AVAudioRecorder`
- Local transcription with `whisper.cpp`
- Optional second-pass cleanup with either:
  - a built-in heuristic refiner
  - a local `llama.cpp` GGUF model
- System-wide text insertion into the frontmost app via `CGEvent`
- Permission checks and quick-open actions for Microphone and Accessibility
- Floating overlay feedback for listening, transcribing, refining, inserting, completion, and errors
- Managed model downloads with in-app progress, activation, and deletion

## Setup

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

## First-run flow

1. Launch the app with `swift run`.
2. Open the menu bar item and then open `Settings`.
3. Grant Microphone and Accessibility access.
4. Resolve `whisper-cli` from Settings if needed.
5. Download a Whisper model from the built-in catalog, or browse to a local `.bin` file.
6. Optionally enable second-pass cleanup and configure `llama.cpp`.

## Model management

Whisper is mandatory; the app provides a built-in model catalog for common local dictation tradeoffs.

The curated catalog currently includes:

- Whisper English and multilingual `whisper.cpp` models
- official Phi-3 Mini GGUF builds for optional `llama.cpp` cleanup

Managed models are stored in:

- `~/Library/Application Support/Voice/Models/Whisper`
- `~/Library/Application Support/Voice/Models/Llama`

Settings supports:

- downloading curated models with live percentage progress
- browsing to custom local `.bin` or `.gguf` files
- switching between downloaded models
- deleting downloaded models that are not active

Downloads do not automatically switch the active model. Newly downloaded models are added to the local library and can be activated manually with `Use`.

## Refinement behavior

The second pass is optional.

- `Heuristic` mode works without any extra model.
- `llama.cpp` mode requires a GGUF model and a local `llama.cpp` install.

When the configured executable is `llama-cli`, the app automatically uses the sibling `llama-completion` binary for non-interactive cleanup if it exists, avoiding chat-mode hangs in recent Homebrew installs. Manual local GGUF files still work for custom Llama 3.2 or Mistral setups.

## Notes

- This project is intentionally packaged as a SwiftPM macOS app so it can build in environments that only have Xcode Command Line Tools installed.
- For a distributable `.app` bundle, wrap the package in an Xcode app target and add `NSMicrophoneUsageDescription` to the generated app's `Info.plist`.
- The current transcription path uses upstream `whisper.cpp` CLI arguments such as `--model`, `--file`, `--output-txt`, `--output-file`, `--no-prints`, and `--no-timestamps`.

## Linux terminal MVP

The `feature/linux-port-mvp` branch adds a terminal-first Linux prototype under `tools/voice-cli`, including a curses TUI that can be launched with `voice`.
See `docs/linux-mvp.md` for setup, dependency checks, and the staged Mint porting roadmap.

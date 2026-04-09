# Voice

`Voice` is a native macOS menu-bar dictation utility scaffold for local-first speech-to-text. It is structured to mimic the workflow of tools like SuperWhisper or Wispr Flow while keeping the inference path local through `whisper.cpp` and an optional second-pass `llama.cpp` cleanup stage.

## What is implemented

- Menu-bar-only SwiftUI app with a status menu and settings scene
- Global hotkey support through `KeyboardShortcuts`
- Local microphone capture to 16 kHz mono WAV via `AVAudioRecorder`
- `whisper.cpp` shell adapter for local transcription
- Optional second pass refinement using either:
  - a built-in heuristic cleanup pass
  - `llama.cpp` through `llama-cli`
- System-wide text insertion into the frontmost app via `CGEvent`
- Accessibility and microphone permission checks plus quick-open buttons
- Floating overlay panel for listen/transcribe/refine/insert feedback

## Local setup

Install the upstream CLIs:

```bash
brew install whisper-cpp llama.cpp
```

Example binary locations on Apple Silicon:

- `whisper-cli`: `/opt/homebrew/bin/whisper-cli`
- `llama-cli`: `/opt/homebrew/bin/llama-cli`

Then open the app settings and provide:

- the `whisper-cli` executable path
- a Whisper model, either by downloading one from the built-in catalog or by browsing to a local `.bin` file
- optionally the `llama-cli` executable path
- optionally a GGUF model for refinement, either from the built-in catalog or from a local `.gguf` file

Managed downloads are stored in:

- `~/Library/Application Support/Voice/Models/Whisper`
- `~/Library/Application Support/Voice/Models/Llama`

The curated in-app catalog currently includes:

- Whisper English and multilingual presets from `whisper.cpp`
- official Phi-3 Mini GGUF builds for optional `llama.cpp` refinement

Manual local model files still work, which is useful for custom Llama 3.2 or Mistral GGUF setups.

## Build and run

```bash
swift build
swift run
```

## Notes

- This project is intentionally packaged as a SwiftPM app scaffold so it can build in environments that only have Xcode Command Line Tools installed.
- For a distributable macOS app bundle, wrap the package in an Xcode app target and add `NSMicrophoneUsageDescription` to the generated app's `Info.plist`.
- `whisper.cpp` argument usage in this project is based on the current upstream CLI flags (`--model`, `--file`, `--output-txt`, `--output-file`, `--no-prints`, `--no-timestamps`).
- `llama.cpp` refinement currently uses the documented `llama-cli -m ... -n ... -p ...` completion flow.
- This Command Line Tools environment does not expose a working Swift package test runtime, so the current verification path is `swift build`.

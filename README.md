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

You still need to download local model files yourself:

- Whisper models: [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- GGUF LLM models: any instruct-tuned model compatible with `llama.cpp`

Then open the app settings and provide:

- the `whisper-cli` executable path
- the local Whisper model path
- optionally the `llama-cli` executable path
- optionally the local GGUF model path for refinement

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

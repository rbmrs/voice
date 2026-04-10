# Repository Guidelines

## Project Structure & Module Organization

`Sources/Voice` contains the macOS SwiftPM app. App lifecycle code lives in `Sources/Voice/App`, SwiftUI screens in `Sources/Voice/Views`, shared state in `Sources/Voice/Models`, platform services in `Sources/Voice/Services`, and small helpers in `Sources/Voice/Utilities`. The Linux terminal prototype lives under `tools/voice-cli`, with supporting notes and roadmap material in `docs/linux-mvp.md`. `voice_logo.png` is the README image asset.

## Build, Test, and Development Commands

- `swift build`: builds the macOS executable package.
- `swift run`: launches the macOS menu-bar app from SwiftPM.
- `python3 tools/voice-cli/voice.py doctor`: checks Linux CLI runtime dependencies.
- `python3 tools/voice-cli/voice.py tui --whisper-model ~/.local/share/voice/models/whisper/ggml-base.en.bin`: starts the curses TUI directly.
- `voice`: starts the Linux TUI through the shell wrapper after configuring the expected model path.

## Coding Style & Naming Conventions

Swift code uses four-space indentation, Swift 6 language mode, `PascalCase` types, and `camelCase` properties, methods, and local variables. Keep SwiftUI views focused and put external process, permissions, audio, and model-management logic in `Services`. Python CLI code follows standard library-first patterns, type hints where useful, `snake_case` functions, and concise user-facing errors through `VoiceCliError`.

## Testing Guidelines

There is no committed automated test suite yet. Before submitting app changes, run `swift build` and manually exercise affected menu-bar or Settings flows. For Linux CLI changes, run `python3 tools/voice-cli/voice.py doctor` plus the specific subcommand you changed, such as `record`, `transcribe`, `run`, or `tui`.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects, for example `Tighten README for conciseness` and `Add managed model downloads and llama refinement fixes`. Keep commits scoped to one behavior or documentation change. Pull requests should describe the user-visible change, list manual verification commands, link related issues when applicable, and include screenshots or terminal output for UI/TUI changes.

## Security & Configuration Tips

Do not commit local model files, generated audio, or machine-specific paths. Keep Whisper and Llama model locations configurable through Settings, CLI flags, or `VOICE_*` environment variables.

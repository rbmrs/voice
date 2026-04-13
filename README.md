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
- Wayland desktop shortcut path through `voice daemon` + `voice trigger`
- Auto-paste into the focused window via `xdotool` (X11 — key combo auto-detected via WM_CLASS, override with `--paste-key`), `wtype` (Wayland best effort), or the Wayland portal keyboard path after explicit setup
- Clipboard copy through `wl-copy`, `xclip`, `xsel`, or OSC 52
- In-TUI Whisper model manager — browse, download, activate, and delete models
- Settings screen (`S`) with persistent toggles for auto-paste, fast mode, and silence trim, plus a thread count stepper (Left/Right)
- Fast mode skips the heuristic cleanup pass and enables silence trimming — recommended for slow or low-power devices
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

The macOS app resolves CLIs by checking `/opt/homebrew/bin`, `/usr/local/bin`,
`~/.local/bin`, and `~/bin` first, then falling back to every directory on `$PATH`.
Tilde paths (e.g. `~/bin/whisper-cli`) are expanded automatically.

Then build and run:

```bash
swift build
./voice
```

`./voice` launches the SwiftPM menu-bar app and keeps the terminal attached while it is running. Quit from the menu bar or press `Ctrl+C` in the terminal.

To make `voice` available directly in your shell, symlink the launcher into a directory on your `PATH`:

```bash
ln -sfn "$PWD/voice" ~/.local/bin/voice
```

### Linux

```bash
bash tools/voice-cli/install.sh
```

Installs system packages through `apt` or `dnf`, inspects your hardware, picks
the best validated backend it can, builds `whisper.cpp`, and wires the `voice`
command to `~/.local/bin`. Then:

```bash
voice        # launch the TUI
```

Force a specific backend when needed:

```bash
bash tools/voice-cli/install.sh --gpu cpu
bash tools/voice-cli/install.sh --gpu vulkan
bash tools/voice-cli/install.sh --gpu cuda
```

On Fedora, `--gpu cpu` is useful as a known-good fallback when Vulkan build or
runtime validation is not ready yet.

See `docs/linux-mvp.md` for GPU options, manual steps, and troubleshooting.

## First-run flow

### macOS

1. Launch the app with `voice` or `./voice`.
2. Open the menu bar item and then open `Settings`.
3. Grant Microphone and Accessibility access.
4. Resolve `whisper-cli` from Settings if needed. This works even for a future packaged `.app`, which may not inherit your shell `PATH`.
5. Download a Whisper model from the built-in catalog, or browse to a local `.bin` file.
6. Optionally enable second-pass cleanup and configure `llama.cpp`.

### Linux

1. Run `python3 tools/voice-cli/voice.py doctor` to check runtime dependencies.
2. Launch the TUI with `voice`.
3. Press `M` to open the model manager and download a Whisper model.
4. Press `R` to start recording, `R` again to stop.
5. On slow or low-power hardware, press `S` and enable **Fast mode** — it activates silence trimming and skips the heuristic cleanup pass. The TUI will also warn if the active model is too large for comfortable CPU-only use.

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
- On Linux, the global hotkey uses X11 `XGrabKey` and does not require root access. Wayland sessions do not support arbitrary global keyboard grabs, so run `voice daemon` and bind your desktop shortcut to `voice trigger --action toggle` instead.
- On Wayland, clipboard copy is the default. For reliable auto-paste, run `voice wayland-setup --enable-auto-paste` first; GNOME may show a system permission dialog labeled `Remote Desktop` or `Remote Interaction`, and Voice uses it only for keyboard paste access.
- On Fedora GNOME Wayland, bind your shortcut to `voice trigger --action toggle`. Portal-backed auto-paste is the supported path; `wtype` remains a best-effort fallback and can still fail when the compositor lacks virtual keyboard support.

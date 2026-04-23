<p align="center">
  <img src="voice_logo.png" alt="Voice logo" width="30%">
</p>

# Voice

`Voice` is a local-first dictation app built around `whisper.cpp` and `llama.cpp`. It follows the workflow of tools like SuperWhisper or Wispr Flow while keeping transcription and optional cleanup on-device.

- **macOS** — native menu-bar app
- **Linux** — terminal-first TUI under `tools/voice-cli`

## Development approach

This repository was built with the help of AI coding assistants in an agentic, human-supervised workflow. The assistants sped up implementation, iteration, and documentation, while project direction, review, and final decisions remained with the maintainer.

## Features

- On-device transcription with `whisper.cpp`
- Optional second-pass cleanup with a built-in heuristic pass or `llama.cpp`
- Global shortcut and floating status overlay on macOS
- System-wide text insertion on macOS via pasteboard restore or direct keystrokes
- TUI workflow on Linux with built-in model management
- Managed model downloads, activation, and deletion on both platforms

## Setup

### macOS

**Install via Homebrew (recommended)**

```bash
brew tap rbmrs/voice https://github.com/rbmrs/voice
brew install --cask voice
```

This also installs `whisper.cpp` and `llama.cpp`.

**Install from the DMG**

1. Download `Voice-<version>.dmg` from the [latest release](https://github.com/rbmrs/voice/releases/latest).
2. Open the DMG and drag **Voice** to the `Applications` folder.
3. Remove quarantine before first launch:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Voice.app
   ```
4. Install the CLIs separately:
   ```bash
   brew install whisper-cpp llama.cpp
   ```
5. Launch **Voice** from `Applications` or Spotlight.

**Build from source (developers)**

```bash
swift build
./voice
```

Requires Swift 6.2+. The `./voice` wrapper launches the app through SwiftPM.

Before cutting a build, run the smoke checks for core settings and text-processing logic:

```bash
bash scripts/smoke-test.sh
```

### Linux

```bash
bash tools/voice-cli/install.sh
```

Then:

```bash
voice        # launch the TUI
```

Force a backend if needed:

```bash
bash tools/voice-cli/install.sh --gpu cpu
bash tools/voice-cli/install.sh --gpu vulkan
bash tools/voice-cli/install.sh --gpu cuda
```

For a clean reinstall:

```bash
voice uninstall
bash tools/voice-cli/install.sh
```

See `docs/linux-mvp.md` for GPU notes and troubleshooting.

## First-run flow

### macOS

1. Launch **Voice** and open **Settings** from the menu-bar window.
2. Grant **Microphone** and **Accessibility**.
3. Download a Whisper model or choose a local `.bin`.
4. Set the **Dictation Shortcut** at the top of Settings.
5. Optional: enable refinement and configure `llama.cpp`.

If Accessibility looks granted but dictation still cannot insert text, click **Prompt** next to Accessibility to reset the stale macOS grant and reopen the system dialog.

### Linux

1. Run `python3 tools/voice-cli/voice.py doctor`.
2. Launch `voice`.
3. Press `M` to download a Whisper model.
4. Press `R` to start and stop recording.
5. On slower hardware, press `S` and enable **Fast mode**.

## Models and refinement

### macOS

- Whisper models: `~/Library/Application Support/Voice/Models/Whisper`
- Refinement models: `~/Library/Application Support/Voice/Models/Llama`

Settings can download curated models, activate them, delete inactive ones, or browse to local `.bin` and `.gguf` files.

### Linux

- Whisper models: `~/.local/share/voice/models/whisper`
- Llama models: `~/.local/share/voice/models/llama`

Press `M` in the TUI to download, activate, or delete Whisper models. The active model is stored in `~/.config/voice/config.json`.

### Refinement

- `Heuristic` works without an extra model.
- `llama.cpp` needs `llama-cli` and a GGUF model.
- If `llama-completion` exists beside `llama-cli`, Voice uses it automatically.

## Linux notes

- X11 uses a real global hotkey via `voice hotkey`.
- On Wayland, bind your desktop shortcut to `voice trigger --action toggle`. If the TUI shows the Wayland trigger as ready, keep the TUI open and no separate `voice daemon` is needed; otherwise run `voice daemon`.
- Clipboard copy is the default on Wayland. For auto-paste, run `voice wayland-setup --enable-auto-paste`.

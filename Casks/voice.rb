# Homebrew Cask for Voice — a local-first dictation menu-bar app.
#
# Install:
#   brew tap rbmrs/voice https://github.com/rbmrs/voice
#   brew install --cask voice
#
# The 2-arg `brew tap` form is required because the repo is named `voice`,
# not `homebrew-voice`. See https://docs.brew.sh/Taps.

cask "voice" do
  version "0.1.4"
  sha256 "8fae8e60757639dd21f169f96215211e539bc7d0238ae8be424c2a403fe46d9e"

  url "https://github.com/rbmrs/voice/releases/download/v#{version}/Voice-#{version}.dmg"
  name "Voice"
  desc "Local-first dictation menu-bar app (whisper.cpp + llama.cpp)"
  homepage "https://github.com/rbmrs/voice"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: ">= :sonoma"
  depends_on formula: "whisper-cpp"
  depends_on formula: "llama.cpp"

  app "Voice.app"

  # Voice is ad-hoc signed (no Apple Developer ID). Stripping the quarantine xattr
  # prevents Gatekeeper's AppTranslocation from launching the app from a read-only
  # randomized path, which would break future Sparkle auto-updates and app-relative
  # file access. Safe because the user is explicitly opting into this tap.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Voice.app"],
                   sudo: false
  end

  uninstall quit: "dev.rafaelbm.voice"

  zap trash: [
    "~/Library/Preferences/dev.rafaelbm.voice.plist",
    "~/Library/Application Support/Voice",
    "~/Library/Caches/dev.rafaelbm.voice",
    "~/Library/Saved Application State/dev.rafaelbm.voice.savedState",
  ]

  caveats <<~EOS
    Voice requires Microphone and Accessibility permissions on first run.
    Grant both in System Settings → Privacy & Security.

    whisper.cpp and llama.cpp binaries are installed via Homebrew and
    auto-discovered. Pick a Whisper model from the app's Settings pane.
  EOS
end

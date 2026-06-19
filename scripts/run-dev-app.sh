#!/bin/zsh
# Build, bundle, sign, and launch Voice as a real .app — the ONLY correct way to test
# TCC permission behavior (Microphone / Accessibility live status).
#
# Why not `swift run`? A bare `.build/debug/voice` binary launched from a terminal has no
# stable TCC identity: macOS attributes its permissions to the *terminal* (the "responsible
# process"), and the "Voice" row in System Settings actually belongs to the installed cask
# app — a different identity. So toggling it never affects the running dev process, and the
# status can't update. Running a bundled .app launched from Finder/`open` fixes the identity.
#
# This uses a DISTINCT dev bundle id (dev.rafaelbm.voice.debug) so the dev app gets its OWN
# TCC row and never collides with the installed cask Voice.app.
#
# Usage: zsh scripts/run-dev-app.sh

set -euo pipefail

root=${0:A:h:h}
cd "$root"

DEV_BUNDLE_ID="dev.rafaelbm.voice.debug"
app="dist/Voice-dev.app"

echo "==> swift build (debug)"
swift build

bin_path=$(swift build --show-bin-path)
exe="$bin_path/voice"
[[ -f "$exe" ]] || { echo "missing binary at $exe"; exit 1; }

echo "==> assembling $app (bundle id: $DEV_BUNDLE_ID)"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$exe" "$app/Contents/MacOS/voice"
chmod +x "$app/Contents/MacOS/voice"
printf 'APPL????' > "$app/Contents/PkgInfo"

[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Info.plist with a dev-only bundle id so this app has its own TCC identity.
sed -e "s/__VERSION__/0.0.0-dev/" -e "s/__BUILD__/0/" \
    -e "s#<string>dev.rafaelbm.voice</string>#<string>$DEV_BUNDLE_ID</string>#" \
    Resources/Info.plist > "$app/Contents/Info.plist"

for bundle in "$bin_path"/*.bundle(N); do
  cp -R "$bundle" "$app/Contents/Resources/"
done

# Ad-hoc sign with entitlements. Ad-hoc cdhash changes each build, so we reset this dev id's
# TCC rows first to avoid stale-grant mismatch — the app then re-prompts cleanly.
echo "==> resetting TCC rows for $DEV_BUNDLE_ID (clears stale ad-hoc grants)"
tccutil reset Accessibility "$DEV_BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$DEV_BUNDLE_ID" 2>/dev/null || true

echo "==> ad-hoc signing"
codesign --force --sign - --entitlements Resources/Voice.entitlements "$app"

echo "==> launching via open (so TCC attributes to the bundle, not the terminal)"
open "$app"

echo ""
echo "==> Voice-dev launched. It appears in System Settings > Privacy as a SEPARATE entry"
echo "    from the installed cask Voice.app. Toggle THIS one to test live status updates."

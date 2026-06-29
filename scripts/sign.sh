#!/bin/zsh
# Ad-hoc sign Voice.app. Free, no Apple Developer ID required.
# Homebrew Cask installs will bypass Gatekeeper via quarantine removal.
# DMG users will see a one-time warning; see README for workaround.
#
# For Developer ID signing, set IDENTITY to your cert CN:
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" zsh scripts/sign.sh

set -euo pipefail

root=${0:A:h:h}
cd "$root"

app=${1:-dist/Voice.app}
[[ -d "$app" ]] || { echo "missing $app — run scripts/build-app.sh first"; exit 1; }

IDENTITY=${IDENTITY:--}
entitlements="Resources/Voice.entitlements"

echo "==> signing $app with identity=$IDENTITY"

# Strip any prior signature, then sign from inside out.
find "$app" -name '*.bundle' -type d -print0 2>/dev/null | while IFS= read -r -d '' b; do
  codesign --remove-signature "$b" 2>/dev/null || true
  codesign --force --sign "$IDENTITY" "$b"
done

# Sign embedded Sparkle.framework inside-out (helpers first, then the framework) so the
# app's --deep --strict verification passes. Voice is non-sandboxed, so Sparkle's XPC
# services go unused; ad-hoc re-signing them without entitlements is fine.
# ponytail: Developer ID signing would also need --options runtime --timestamp on these.
fw="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$fw" ]]; then
  echo "==> signing Sparkle.framework (inside-out)"
  for inner in \
    "$fw"/Versions/*/XPCServices/*.xpc(N) \
    "$fw"/Versions/*/Updater.app(N) \
    "$fw"/Versions/*/Autoupdate(N); do
    codesign --force --sign "$IDENTITY" "$inner"
  done
  codesign --force --sign "$IDENTITY" "$fw"
fi

codesign --remove-signature "$app" 2>/dev/null || true

sign_args=(--force --sign "$IDENTITY" --entitlements "$entitlements")
if [[ "$IDENTITY" != "-" ]]; then
  sign_args+=(--options runtime --timestamp)
fi

codesign "${sign_args[@]}" "$app"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$app"

echo "==> spctl assessment (ad-hoc will be rejected — expected)"
spctl -a -vv "$app" || true

echo "==> done"

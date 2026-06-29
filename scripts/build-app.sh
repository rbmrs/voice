#!/bin/zsh
# Build universal Voice.app bundle from SwiftPM executable.
# Output: dist/Voice.app
# Env: VERSION (default: git describe), BUILD (default: git commit count)
#      ARCHS (default: "arm64 x86_64"), CONFIG (default: release)

set -euo pipefail

root=${0:A:h:h}
cd "$root"

VERSION=${VERSION:-$(git describe --tags --dirty --always 2>/dev/null || echo 0.0.0)}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
CONFIG=${CONFIG:-release}
# Universal build requires full Xcode. Default: host arch only.
# Set UNIVERSAL=1 to build arm64 + x86_64 (needs Xcode.app installed).
UNIVERSAL=${UNIVERSAL:-0}

arch_flags=()
if [[ "$UNIVERSAL" == "1" ]]; then
  arch_flags=(--arch arm64 --arch x86_64)
  echo "==> version=$VERSION build=$BUILD archs=arm64,x86_64"
else
  echo "==> version=$VERSION build=$BUILD arch=host"
fi

echo "==> swift build"
swift build -c "$CONFIG" "${arch_flags[@]}"

bin_path=$(swift build -c "$CONFIG" "${arch_flags[@]}" --show-bin-path)
exe="$bin_path/voice"
[[ -f "$exe" ]] || { echo "missing binary at $exe"; exit 1; }

app="dist/Voice.app"
echo "==> assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$exe" "$app/Contents/MacOS/voice"
chmod +x "$app/Contents/MacOS/voice"

# PkgInfo
printf 'APPL????' > "$app/Contents/PkgInfo"

# Icon — generate if missing
if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "==> generating AppIcon.icns"
  zsh scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Info.plist — substitute version/build placeholders
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    Resources/Info.plist > "$app/Contents/Info.plist"

# Copy SPM resource bundles if any exist (KeyboardShortcuts etc. ship none needed at runtime).
for bundle in "$bin_path"/*.bundle(N); do
  cp -R "$bundle" "$app/Contents/Resources/"
done

# Embed Sparkle.framework (the auto-updater). SwiftPM stages it in the bin path.
# The executable finds it via the @executable_path/../Frameworks rpath set in Package.swift.
if [[ -d "$bin_path/Sparkle.framework" ]]; then
  echo "==> embedding Sparkle.framework"
  mkdir -p "$app/Contents/Frameworks"
  ditto "$bin_path/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
else
  echo "WARNING: Sparkle.framework not at $bin_path — in-app updates will be disabled"
fi

echo "==> done: $app"
ls -la "$app/Contents"

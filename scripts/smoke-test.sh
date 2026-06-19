#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-smoke-tests.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# Guard against contract drift: regenerate the contract into a temp file and
# fail if it differs from the checked-in generated source.
GEN_FILE="$ROOT_DIR/Sources/Voice/Generated/RefinementContract.swift"
GEN_BACKUP="$TMP_DIR/RefinementContract.checked-in.swift"
cp "$GEN_FILE" "$GEN_BACKUP"
swift "$ROOT_DIR/scripts/gen-refinement-contract.swift" >/dev/null
if ! diff -q "$GEN_BACKUP" "$GEN_FILE" >/dev/null; then
  echo "ERROR: $GEN_FILE is out of date with Resources/refinement-contract.json." >&2
  echo "Run: swift scripts/gen-refinement-contract.swift" >&2
  cp "$GEN_BACKUP" "$GEN_FILE"
  exit 1
fi

swiftc \
  "$ROOT_DIR/Sources/Voice/Services/ToolDiscovery.swift" \
  "$ROOT_DIR/Sources/Voice/Services/DictationServiceError.swift" \
  "$ROOT_DIR/Sources/Voice/Services/ShellCommandRunner.swift" \
  "$ROOT_DIR/Sources/Voice/Generated/RefinementContract.swift" \
  "$ROOT_DIR/Sources/Voice/Models/AppSettings.swift" \
  "$ROOT_DIR/Sources/Voice/Services/TextRefiner.swift" \
  "$ROOT_DIR/scripts/voice-smoke-tests.swift" \
  -o "$TMP_DIR/voice-smoke-tests"

"$TMP_DIR/voice-smoke-tests"

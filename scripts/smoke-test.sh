#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-smoke-tests.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc \
  "$ROOT_DIR/Sources/Voice/Services/ToolDiscovery.swift" \
  "$ROOT_DIR/Sources/Voice/Services/DictationServiceError.swift" \
  "$ROOT_DIR/Sources/Voice/Services/ShellCommandRunner.swift" \
  "$ROOT_DIR/Sources/Voice/Models/AppSettings.swift" \
  "$ROOT_DIR/Sources/Voice/Services/TextRefiner.swift" \
  "$ROOT_DIR/scripts/voice-smoke-tests.swift" \
  -o "$TMP_DIR/voice-smoke-tests"

"$TMP_DIR/voice-smoke-tests"

#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
BIN_DIR="$WORKSPACE_ROOT/bin/cli"
BIN_PATH="$BIN_DIR/UnifyIMECLI"

rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"

SWIFT_SOURCES=("${(@f)$(find "$ROOT/Sources" "$WORKSPACE_ROOT/src/phoneticIME/Sources" "$WORKSPACE_ROOT/src/englishIME/Sources" -name '*.swift' | sort)}")

swiftc \
  -D UNIFYIME_CLI \
  -parse-as-library \
  -module-name UnifyIMECLI \
  -target arm64-apple-macos15.0 \
  -framework AppKit \
  -framework Carbon \
  -framework CoreML \
  -framework InputMethodKit \
  -framework WebKit \
  "${SWIFT_SOURCES[@]}" \
  -o "$BIN_PATH"

echo "$BIN_PATH"

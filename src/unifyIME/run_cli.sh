#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
MAIN_SOURCE="$ROOT/Sources/main.swift"
OTHER_SOURCES=("${(@f)$(find "$ROOT/Sources" "$WORKSPACE_ROOT/src/phoneticIME/Sources" -name '*.swift' ! -path "$MAIN_SOURCE" | sort)}")

swift \
  -D UNIFYIME_CLI \
  -target arm64-apple-macos15.0 \
  -framework AppKit \
  -framework Carbon \
  -framework CoreML \
  -framework InputMethodKit \
  "$MAIN_SOURCE" \
  "${OTHER_SOURCES[@]}" \
  -- "$@"

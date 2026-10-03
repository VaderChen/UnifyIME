#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
BIN_DIR="${UNIFYIME_CLI_BUILD_DIR:-$WORKSPACE_ROOT/bin/cli}"
BIN_PATH="$BIN_DIR/UnifyIMECLI"
SWIFT_CONFIGURATION="${UNIFYIME_SWIFT_CONFIGURATION:-${FASTCHIME_SWIFT_CONFIGURATION:-debug}}"

for arg in "$@"; do
  case "$arg" in
    --release) SWIFT_CONFIGURATION="release" ;;
    --debug) SWIFT_CONFIGURATION="debug" ;;
    *) echo "不支援的參數：$arg" >&2; exit 2 ;;
  esac
done

SWIFT_FLAGS=()
case "$SWIFT_CONFIGURATION" in
  debug) SWIFT_FLAGS+=(-Onone -D DEBUG) ;;
  release) SWIFT_FLAGS+=(-O -whole-module-optimization) ;;
  *) echo "不支援的 Swift 建置模式：$SWIFT_CONFIGURATION" >&2; exit 2 ;;
esac

mkdir -p "$BIN_DIR"

SWIFT_SOURCES=("${(@f)$(find "$ROOT/Sources" "$WORKSPACE_ROOT/src/phoneticIME/Sources" "$WORKSPACE_ROOT/src/englishIME/Sources" -name '*.swift' | sort)}")

BUILD_PATH="$(mktemp "$BIN_DIR/.UnifyIMECLI.XXXXXX")"
trap 'rm -f "$BUILD_PATH"' EXIT

swiftc \
  -D UNIFYIME_CLI \
  "${SWIFT_FLAGS[@]}" \
  -parse-as-library \
  -module-name UnifyIMECLI \
  -target "${UNIFYIME_ARCH:-${FASTCHIME_ARCH:-$(uname -m)}}-apple-macos${UNIFYIME_MACOS_TARGET:-${FASTCHIME_MACOS_TARGET:-13.0}}" \
  -framework AppKit \
  -framework Carbon \
  -framework CoreML \
  -framework InputMethodKit \
  -framework WebKit \
  "${SWIFT_SOURCES[@]}" \
  -o "$BUILD_PATH"

mv -f "$BUILD_PATH" "$BIN_PATH"

echo "$BIN_PATH"

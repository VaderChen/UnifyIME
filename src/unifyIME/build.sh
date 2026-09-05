#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
MODULE_NAME="UnifyIME"
APP_NAME="全一輸入法.app"
APP_BUILD_DIR="$WORKSPACE_ROOT/bin/app"
APP_DIR="$APP_BUILD_DIR/$APP_NAME"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
INPUT_METHODS_DIR="$HOME/Library/Input Methods"
INSTALL_DIR="$INPUT_METHODS_DIR/$APP_NAME"
HOST_ARCH="${UNIFYIME_ARCH:-${FASTCHIME_ARCH:-$(uname -m)}}"
MACOS_TARGET="${UNIFYIME_MACOS_TARGET:-${FASTCHIME_MACOS_TARGET:-13.0}}"
DEPLOY_MODE="${UNIFYIME_DEPLOY:-${FASTCHIME_DEPLOY:-0}}"
SKIP_SIGN="${UNIFYIME_SKIP_SIGN:-${FASTCHIME_SKIP_SIGN:-0}}"
SIGN_IDENTITY="${SIGN_IDENTITY:-${UNIFYIME_SIGN_IDENTITY:-${FASTCHIME_SIGN_IDENTITY:--}}}"
SWIFT_CONFIGURATION="${UNIFYIME_SWIFT_CONFIGURATION:-${FASTCHIME_SWIFT_CONFIGURATION:-debug}}"

for arg in "$@"; do
  case "$arg" in
    --deploy)
      DEPLOY_MODE=1
      ;;
    --no-deploy)
      DEPLOY_MODE=0
      ;;
    --skip-sign)
      SKIP_SIGN=1
      ;;
    --sign)
      SKIP_SIGN=0
      ;;
    --arch=*)
      HOST_ARCH="${arg#*=}"
      ;;
    --macos-target=*)
      MACOS_TARGET="${arg#*=}"
      ;;
    --sign-identity=*)
      SIGN_IDENTITY="${arg#*=}"
      ;;
    --release)
      SWIFT_CONFIGURATION="release"
      ;;
    --debug)
      SWIFT_CONFIGURATION="debug"
      ;;
  esac
done

case "$HOST_ARCH" in
  arm64|x86_64)
    ;;
  *)
    echo "Unsupported arch: $HOST_ARCH" >&2
    exit 2
    ;;
esac

case "$SWIFT_CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "Unsupported swift configuration: $SWIFT_CONFIGURATION" >&2
    exit 2
    ;;
esac

TARGET_TRIPLE="$HOST_ARCH-apple-macos$MACOS_TARGET"
SWIFT_FLAGS=()
if [[ "$SWIFT_CONFIGURATION" == "debug" ]]; then
  SWIFT_FLAGS+=(-D DEBUG)
fi

remove_stale_input_methods() {
  local app current_id app_id app_name display_name
  current_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
  [[ -d "$INPUT_METHODS_DIR" ]] || return 0

  while IFS= read -r -d '' app; do
    [[ "$app" == "$INSTALL_DIR" ]] && continue
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    app_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist" 2>/dev/null || true)"
    display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Contents/Info.plist" 2>/dev/null || true)"

    if [[ "$app_id" == "$current_id" ]] \
      || [[ "$app_id" == com.vader.inputmethod.* ]] \
      || [[ "$app_id" == dev.vader.inputmethod.FastChIME.* ]] \
      || [[ "$app_id" == com.vader.inputmethod.FastChIME* ]] \
      || [[ "$app_id" == com.vader.inputmethod.UnifyIME* ]] \
      || [[ "$app_name" == "快捷中文測試" ]] \
      || [[ "$display_name" == "快捷中文測試" ]] \
      || [[ "$app_name" == "快捷中文輸入" ]] \
      || [[ "$display_name" == "快捷中文輸入" ]] \
      || [[ "$app_name" == "全一輸入法" ]] \
      || [[ "$display_name" == "全一輸入法" ]]; then
      echo "Removing stale input method:"
      echo "  $app"
      rm -rf "$app"
    fi
  done < <(find "$INPUT_METHODS_DIR" -maxdepth 1 -type d -name '*.app' -print0)
}

copy_tree_if_exists() {
  local src="$1"
  local dst="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$dst"
  ditto "$src" "$dst"
}

remove_appledouble_files() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  find "$target" -name '._*' -delete
}

rm -rf "$APP_BUILD_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR/Base.lproj" "$RES_DIR/en.lproj" "$RES_DIR/zh-Hant.lproj"

SWIFT_SOURCES=("${(@f)$(find "$ROOT/Sources" "$WORKSPACE_ROOT/src/phoneticIME/Sources" "$WORKSPACE_ROOT/src/englishIME/Sources" -name '*.swift' ! -name '._*' | sort)}")

swiftc \
  -parse-as-library \
  -module-name "$MODULE_NAME" \
  -target "$TARGET_TRIPLE" \
  -framework AppKit \
  -framework Carbon \
  -framework CoreML \
  -framework InputMethodKit \
  "${SWIFT_FLAGS[@]}" \
  "${SWIFT_SOURCES[@]}" \
  -o "$BIN_DIR/$MODULE_NAME"

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/Bopomofo.tiff" "$RES_DIR/Bopomofo.tiff"
cp "$ROOT/Resources/common_map.tsv" "$RES_DIR/common_map.tsv"
cp "$ROOT/Resources/phrase_map.tsv" "$RES_DIR/phrase_map.tsv"
cp "$ROOT/Resources/Base.lproj/InfoPlist.strings" "$RES_DIR/Base.lproj/InfoPlist.strings"
cp "$ROOT/Resources/en.lproj/InfoPlist.strings" "$RES_DIR/en.lproj/InfoPlist.strings"
cp "$ROOT/Resources/zh-Hant.lproj/InfoPlist.strings" "$RES_DIR/zh-Hant.lproj/InfoPlist.strings"

if [[ -d "$WORKSPACE_ROOT/src/englishIME/Resources" ]]; then
  find "$WORKSPACE_ROOT/src/englishIME/Resources" -type f ! -name '._*' | while read -r resource; do
    cp "$resource" "$RES_DIR/$(basename "$resource")"
  done
fi

copy_tree_if_exists "$ROOT/Resources/Models" "$RES_DIR/Models"
remove_appledouble_files "$APP_DIR"

if [[ "$SKIP_SIGN" != "1" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Resources/fastChIME.entitlements" "$APP_DIR"
  codesign --verify --deep --strict "$APP_DIR"
else
  echo "Skipping codesign"
fi

if [[ "$DEPLOY_MODE" == "1" && "${UNIFYIME_SKIP_DEPLOY:-${FASTCHIME_SKIP_DEPLOY:-0}}" != "1" ]]; then
  echo "Build mode: deploy"
else
  echo "Build mode: local-only"
fi

echo "Arch: $HOST_ARCH"
echo "Target: $TARGET_TRIPLE"
echo "Swift configuration: $SWIFT_CONFIGURATION"

if [[ "$DEPLOY_MODE" == "1" && "${UNIFYIME_SKIP_DEPLOY:-${FASTCHIME_SKIP_DEPLOY:-0}}" != "1" ]]; then
  echo "Deploying to:"
  echo "  $INSTALL_DIR"
  remove_stale_input_methods
  rm -rf "$INSTALL_DIR"
  ditto "$APP_DIR" "$INSTALL_DIR"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR"
  killall UnifyIME >/dev/null 2>&1 || true
  killall "快捷中文測試" >/dev/null 2>&1 || true
  killall TextInputMenuAgent >/dev/null 2>&1 || true
  killall cfprefsd >/dev/null 2>&1 || true
  pkill -f "$INSTALL_DIR/Contents/MacOS/UnifyIME" >/dev/null 2>&1 || true
  pkill -f "$INSTALL_DIR/Contents/MacOS/UnifyIME basicSelWindow" >/dev/null 2>&1 || true
  open -gja "$INSTALL_DIR"
  sleep 1
  open -na "$INSTALL_DIR" --args basicSelWindow
  echo "Deployed and reloaded:"
  echo "  $INSTALL_DIR"
fi

echo "$APP_DIR"

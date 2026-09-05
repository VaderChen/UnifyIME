#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="$SCRIPT_DIR"
DIST_ROOT="$PROJECT_ROOT/dist"
APP_NAME="全一輸入法.app"
APP_SOURCE="$DIST_ROOT/$APP_NAME"
SOURCE_BUILD_SCRIPT="$PROJECT_ROOT/src/unifyIME/build.sh"
PACK_STAGE=""
BUILD_FIRST="false"

cleanup_stage() {
  if [[ -n "$PACK_STAGE" && -d "$PACK_STAGE" ]]; then
    /bin/rm -rf -- "$PACK_STAGE"
  fi
}
trap cleanup_stage EXIT INT TERM

print_usage() {
  cat <<'USAGE'
用法：./pack.command [--no-build|--build]

以 dist/全一輸入法.app 建立 macOS DMG。

選項：
  --no-build  直接使用 dist 中現有的 app（預設）
  --build     先執行 build.command，再使用新的 app
  -h, --help  顯示本說明
USAGE
}

for argument in "$@"; do
  case "$argument" in
    --no-build)
      BUILD_FIRST="false"
      ;;
    --build)
      BUILD_FIRST="true"
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      print -u2 "錯誤：不支援的參數：$argument"
      print_usage >&2
      exit 2
      ;;
  esac
done

for command_name in hdiutil ditto mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print -u2 "錯誤：找不到必要工具：$command_name"
    exit 1
  fi
done

if [[ "$BUILD_FIRST" == "true" ]]; then
  if [[ ! -f "$SOURCE_BUILD_SCRIPT" ]]; then
    print -u2 "錯誤：找不到專案建置腳本：$SOURCE_BUILD_SCRIPT"
    exit 1
  fi
  zsh "$SOURCE_BUILD_SCRIPT" --skip-sign --no-deploy
fi

if [[ -L "$DIST_ROOT" || ! -d "$DIST_ROOT" ]]; then
  print -u2 "錯誤：dist 必須是實體目錄：$DIST_ROOT"
  exit 1
fi
if [[ ! -d "$APP_SOURCE/Contents" || ! -x "$APP_SOURCE/Contents/MacOS/UnifyIME" ]]; then
  print -u2 "錯誤：找不到可封裝的 app：$APP_SOURCE"
  exit 1
fi

PACK_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/unifyime-pack.XXXXXX")"
IMAGE_ROOT="$PACK_STAGE/UnifyIME"
/bin/mkdir -p "$IMAGE_ROOT"
/usr/bin/ditto "$APP_SOURCE" "$IMAGE_ROOT/$APP_NAME"
/bin/ln -s /Applications "$IMAGE_ROOT/Applications"

timestamp="$(TZ=Asia/Taipei date '+%Y%m%d-%H%M%S')"
output_path="$DIST_ROOT/UnifyIME-$timestamp.dmg"

print "建立 DMG：$output_path"
/usr/bin/hdiutil create \
  -volname "UnifyIME" \
  -srcfolder "$IMAGE_ROOT" \
  -ov \
  -format UDZO \
  "$output_path"

/usr/bin/hdiutil imageinfo "$output_path" >/dev/null
print "封裝完成："
print "  $output_path"

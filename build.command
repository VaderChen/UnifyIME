#!/bin/zsh
# FastChIME 可安裝檔建置腳本
# Finder 雙擊即可執行；預設只產生 .app，不部署系統輸入法。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR"
BUILD_SCRIPT="$ROOT/src/unifyIME/build.sh"
OUTPUT_DIR="$ROOT/dist"

if [[ ! -f "$BUILD_SCRIPT" ]]; then
  echo "找不到建置腳本：$BUILD_SCRIPT" >&2
  exit 1
fi

# 只有明確傳入 --deploy 時才部署；其餘參數交由主建置腳本處理。
ARGS=(--skip-sign --no-deploy)
for arg in "$@"; do
  case "$arg" in
    --deploy)
      ARGS+=(--deploy)
      ;;
    --sign)
      # --sign 會覆蓋預設的 --skip-sign
      ARGS+=(--sign)
      ;;
    --release|--debug|--arch=*|--macos-target=*|--sign-identity=*)
      ARGS+=("$arg")
      ;;
    --help|-h)
      cat <<'HELP'
用法：
  build.command [選項]

選項：
  --release             建置 release 版本
  --debug               建置 debug 版本（預設）
  --sign                使用 codesign 簽章
  --deploy              建置後部署到 macOS 輸入法目錄
  --arch=ARCH           指定 arm64 或 x86_64
  --macos-target=VER    指定最低 macOS 版本
  --sign-identity=ID    指定簽章身分
HELP
      exit 0
      ;;
    *)
      echo "未知選項：$arg" >&2
      exit 2
      ;;
  esac
done

# 主建置腳本會先清空 dist，再產生本次建置。
echo "開始建置 FastChIME…"
zsh "$BUILD_SCRIPT" "${ARGS[@]}"

APP_SOURCE="$ROOT/bin/app/全一輸入法.app"
mkdir -p "$OUTPUT_DIR"
APP_DEST="$OUTPUT_DIR/全一輸入法.app"
if [[ ! -d "$APP_SOURCE" ]]; then
  echo "建置完成但找不到 app 產物：$APP_SOURCE" >&2
  exit 1
fi

# 將可安裝 app 複製到 dist，保留 bin/app 作為建置輸出。
rm -rf "$APP_DEST"
ditto "$APP_SOURCE" "$APP_DEST"

echo
echo "可安裝檔已建立："
echo "  $APP_DEST"
echo "可用 --deploy 安裝至使用者輸入法目錄，或執行 pack.command 製作安裝 DMG。"

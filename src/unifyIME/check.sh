#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
APP_BIN="$WORKSPACE_ROOT/bin/app/全一輸入法.app/Contents/MacOS/UnifyIME"
RUN_SELFTEST=1
BUILD_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --skip-selftest)
      RUN_SELFTEST=0
      ;;
    *)
      BUILD_ARGS+=("$arg")
      ;;
  esac
done

if [[ ! " ${BUILD_ARGS[*]} " =~ " --skip-sign " ]]; then
  BUILD_ARGS+=(--skip-sign)
fi
if [[ ! " ${BUILD_ARGS[*]} " =~ " --no-deploy " && ! " ${BUILD_ARGS[*]} " =~ " --deploy " ]]; then
  BUILD_ARGS+=(--no-deploy)
fi

"$ROOT/build.sh" "${BUILD_ARGS[@]}"

echo
echo "[check] smoke: ranker-status"
"$APP_BIN" ranker-status

if [[ "$RUN_SELFTEST" == "1" ]]; then
  echo
  echo "[check] continuous mixed-input smoke"
  python3 "$ROOT/scripts/mixed_live_smoke.py"

  echo
  echo "[check] raw selftest"
  python3 "$ROOT/scripts/raw_selftest.py"
fi

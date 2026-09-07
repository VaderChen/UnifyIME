#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 更新資料結構時，優先改這裡的 include/exclude 規則。
typeset -a COMMON_EXCLUDES
COMMON_EXCLUDES=(
  "backup.zip"
  "backup.slim.zip"
  "backup.source-only.zip"
  "FastChiIME_*.zip"
  "bin/*"
  "temp/*"
  "tranSet/*"
  "src/unifyIME/artifacts/*"
  "src/unifyIME/build/*"
  "src/unifyIME/build-cli/*"
  "src/unifyIME/build-testhost/*"
  "src/unifyIME/debug-build/*"
  "src/unifyIME/debug-logs/*"
  "feature_cache/*"
  "*/feature_cache/*"
  "refCode/vChewing/build-vChewing-arm64/*"
  "*/__pycache__/*"
  "__pycache__/*"
  "*.DS_Store"
  "*/._*"
  "._*"
  "*.bak"
)

typeset -a SLIM_EXCLUDES
SLIM_EXCLUDES=(
  "refCode/*"
  "data/user_selection/*"
)

typeset -a SOURCE_ONLY_INPUTS
SOURCE_ONLY_INPUTS=(
  "backup-full.command"
  "backup-slim.command"
  "backup-source-only.command"
  "doc"
  "scripts"
  "cert"
  "src/englishIME/Sources"
  "src/englishIME/scripts"
  "src/englishIME/Resources"
  "src/phoneticIME/Sources"
  "src/unifyIME/Sources"
  "src/unifyIME/scripts"
  "src/unifyIME/Resources/common_map.tsv"
  "src/unifyIME/Resources/phrase_map.tsv"
  "src/unifyIME/Resources/Bopomofo.tiff"
  "src/unifyIME/Resources/Info.plist"
  "src/unifyIME/Resources/fastChIME.entitlements"
  "src/unifyIME/Resources/Base.lproj"
  "src/unifyIME/Resources/en.lproj"
  "src/unifyIME/Resources/zh-Hant.lproj"
  "src/unifyIME/build.sh"
  "src/unifyIME/build_cli.sh"
  "src/unifyIME/run_cli.sh"
  "src/unifyIME/test_train.sh"
  "src/unifyIME/COREML_RANKER.md"
  "src/unifyIME/TRAINING_DATA_DESIGN.md"
  "src/unifyIME/TRAIN_RANKER_SPEC.md"
  "src/unifyIME/SKILL_INTEGRATION.md"
  "src/unifyIME/tests/regression_cases.jsonl"
  "misc"
  ".claude"
)

run_backup() {
  local mode="$1"
  local variant="$2"
  shift 2

  local -a inputs=("$@")
  local -a excludes=("${COMMON_EXCLUDES[@]}")

  case "$mode" in
    full)
      ;;
    slim)
      excludes+=("${SLIM_EXCLUDES[@]}")
      ;;
    source-only)
      ;;
    *)
      echo "unknown backup mode: $mode" >&2
      return 1
      ;;
  esac

  local stamp
  stamp="$(date +%Y%m%d)"
  local output_name="FastChiIME_${variant}_${stamp}.zip"
  local output_path="$ROOT/$output_name"
  rm -f "$output_path"

  (
    cd "$ROOT"
    find . -name '._*' -delete
    zip -r "$output_name" "${inputs[@]}" -x "${excludes[@]}"
  )

  stat -f '%N %z bytes %Sm' -t '%Y-%m-%d %H:%M:%S' "$output_path"
}

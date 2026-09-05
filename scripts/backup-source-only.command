#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/backup_common.sh"

run_backup source-only "backup.source-only.zip" "${SOURCE_ONLY_INPUTS[@]}"

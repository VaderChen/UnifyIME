#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/backup_common.sh"

run_backup slim "backup.slim.zip" doc scripts cert data src misc .claude

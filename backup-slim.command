#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/scripts/backup_common.sh"

run_backup slim "slim" doc scripts cert data src misc .claude

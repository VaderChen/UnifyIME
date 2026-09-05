#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/scripts/backup_common.sh"

run_backup source-only "source-only" "${SOURCE_ONLY_INPUTS[@]}"

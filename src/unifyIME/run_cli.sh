#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_PATH="$(zsh "$ROOT/build_cli.sh")"
exec "$BIN_PATH" "$@"

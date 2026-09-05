#!/bin/zsh
set -euo pipefail

INSTALL="$HOME/Library/Input Methods/全一輸入法.app"

echo "Reloading UnifyIME..."

killall UnifyIME >/dev/null 2>&1 || true
killall "快捷中文測試" >/dev/null 2>&1 || true
killall TextInputMenuAgent >/dev/null 2>&1 || true
killall cfprefsd >/dev/null 2>&1 || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL" >/dev/null 2>&1 || true

open -gja "$INSTALL"
sleep 1
open -na "$INSTALL" --args basicSelWindow

echo
echo "Reload complete:"
echo "  $INSTALL"

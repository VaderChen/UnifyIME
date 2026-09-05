#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IME_ROOT="$ROOT/src/unifyIME"
APP="$ROOT/bin/app/全一輸入法.app"
INSTALL="$HOME/Library/Input Methods/全一輸入法.app"
TARGET_IME="全一輸入法"

echo "Building development app..."
"$IME_ROOT/build.sh"

echo "Installing to:"
echo "  $INSTALL"
rm -rf "$INSTALL"
ditto "$APP" "$INSTALL"

echo "Refreshing registration..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL"
killall UnifyIME >/dev/null 2>&1 || true
killall "快捷中文測試" >/dev/null 2>&1 || true
killall TextInputMenuAgent >/dev/null 2>&1 || true
killall cfprefsd >/dev/null 2>&1 || true

echo
echo "Done."
echo "Installed development build:"
echo "  $INSTALL"
echo
echo "IME reloaded."
echo "This flow does not notarize. Use build-release-notarize.command"
echo "when you need system-list / release-level validation."

open -gja "$INSTALL"
sleep 1
open -na "$INSTALL" --args basicSelWindow

echo
echo "IME server launched."
echo "Candidate helper launched (hidden until composition/candidates exist)."
echo "Switch manually to ${TARGET_IME} in the input menu, then type in your target app."

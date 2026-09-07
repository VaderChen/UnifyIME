#!/bin/zsh
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$WORKSPACE_ROOT/src/unifyIME"
APP="$WORKSPACE_ROOT/bin/app/全一輸入法.app"
INSTALL="$HOME/Library/Input Methods/全一輸入法.app"
STAGE="$ROOT/notary-stage"
ZIP="$ROOT/UnifyIME-$(date +%Y%m%d-%H%M%S).zip"
PROFILE="${FASTCHIME_NOTARY_PROFILE:?Set FASTCHIME_NOTARY_PROFILE to your Keychain notarization profile}"

echo "Building release app..."
"$ROOT/build.sh"

echo "Preparing notarization archive..."
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/UnifyIME.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGE/UnifyIME.app" "$ZIP"

echo "Submitting to Apple notarization service..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling build artifact..."
xcrun stapler staple "$APP"
stapler validate "$APP"

echo "Installing notarized app..."
rm -rf "$INSTALL"
ditto "$APP" "$INSTALL"
xcrun stapler staple "$INSTALL"

echo "Refreshing registration..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL"
killall UnifyIME >/dev/null 2>&1 || true
killall TextInputMenuAgent >/dev/null 2>&1 || true
killall cfprefsd >/dev/null 2>&1 || true

echo
echo "Done."
echo "Installed notarized build:"
echo "  $INSTALL"
echo
echo "IME reloaded."
spctl -a -vv "$INSTALL"

#!/bin/bash
# Builds Sill.app. No Xcode project and no Apple Developer account.
#
# Signing: an ad-hoc signature (`--sign -`) has NO stable designated requirement —
# its requirement is a literal hash of the binary. macOS keys the Accessibility
# grant to that requirement, so with ad-hoc signing the grant DIES ON EVERY REBUILD
# and the user has to re-approve after every `git pull`.
#
# The fix is a self-signed certificate, created once, free, no Apple account:
#   Keychain Access → Certificate Assistant → Create a Certificate…
#   Name: "Sill Dev"   Identity Type: Self Signed Root   Type: Code Signing
# Then build with:  SILL_SIGN_IDENTITY="Sill Dev" ./build.sh
#
# Without it the app still builds and runs — you just re-grant Accessibility each time.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="build/Sill.app"
IDENTITY="${SILL_SIGN_IDENTITY:--}"

echo "→ compiling ($CONFIG, universal)"
# Both slices: LSMinimumSystemVersion claims macOS 14, which still has Intel Macs.
# An arm64-only binary would simply fail to launch for them.
swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/Sill"

echo "→ assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sill"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/Sill.icns ] && cp Resources/Sill.icns "$APP/Contents/Resources/Sill.icns"

# No --deep: deprecated for signing since macOS 13, and there is no nested code.
# No 2>/dev/null: a silent signing failure produces a bundle that won't launch at
# all on Apple silicon, with no clue why.
echo "→ signing as: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier app.sill.Sill "$APP"

if [ "$IDENTITY" = "-" ]; then
    echo "   note: ad-hoc — macOS will forget Accessibility on the next rebuild."
    echo "         See the header of this script to fix that permanently."
fi

echo "→ built $APP"
lipo -info "$APP/Contents/MacOS/Sill" | sed 's/^/   /'

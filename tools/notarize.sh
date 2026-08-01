#!/bin/bash
# Signs, notarizes and staples Sill.app — run by someone with an Apple Developer account.
#
#   ./tools/notarize.sh "Developer ID Application: Jane Smith (AB12CD34EF)" AB12CD34EF
#
# Needs, one time, a keychain profile holding your Apple credentials:
#
#   xcrun notarytool store-credentials "sill-notary" \
#       --apple-id "you@example.com" \
#       --team-id "AB12CD34EF" \
#       --password "abcd-efgh-ijkl-mnop"     # app-specific password, NOT your Apple password
#
# Make the app-specific password at appleid.apple.com → Sign-In and Security →
# App-Specific Passwords. Apple rejects your real password here.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${1:-}"
TEAM_ID="${2:-}"
PROFILE="${3:-sill-notary}"

if [ -z "$IDENTITY" ] || [ -z "$TEAM_ID" ]; then
    echo "usage: ./tools/notarize.sh \"Developer ID Application: NAME (TEAMID)\" TEAMID [keychain-profile]"
    echo
    echo "Your signing identities:"
    security find-identity -v -p codesigning | grep "Developer ID Application" || \
        echo "  (none found — install your Developer ID certificate from developer.apple.com)"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="build/Sill.app"
ZIP="build/Sill-${VERSION}.zip"

echo "→ building universal release"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Sill"

echo "→ assembling bundle"
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sill"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/Sill.icns ] && cp Resources/Sill.icns "$APP/Contents/Resources/Sill.icns"
xattr -cr "$APP"

# --options runtime enables the hardened runtime, which Apple REQUIRES for notarization.
# --timestamp is also required. No entitlements file: Sill is not sandboxed, and the
# Accessibility APIs it uses need no entitlement.
echo "→ signing with: $IDENTITY"
codesign --force --timestamp --options runtime \
         --identifier app.sill.Sill \
         --sign "$IDENTITY" "$APP"

echo "→ verifying signature"
codesign --verify --strict --verbose=2 "$APP"

# ditto, not zip — `zip` does not preserve the code signature.
echo "→ zipping for submission"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ submitting to Apple (usually 1–5 minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Stapling attaches the ticket to the app so it opens even offline.
echo "→ stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "→ re-zipping the stapled app for release"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ final check — this is what a user's Mac will do"
spctl -a -t exec -vvv "$APP"

echo
echo "Done. Ship $ZIP"
echo "It should now open on any Mac with no warning."

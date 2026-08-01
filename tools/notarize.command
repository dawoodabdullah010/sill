#!/bin/bash
# Double-click this. It signs and notarizes the Sill.app sitting next to it.
# Everything it needs, it asks for. Safe to run again if it fails partway.
cd "$(dirname "$0")"
clear 2>/dev/null || true

say()  { echo "$@"; }
die()  { echo; echo "✗ $1"; echo; shift; for l in "$@"; do echo "  $l"; done
         echo; read -n 1 -s -r -p "Press any key to close."; exit 1; }

echo "──────────────────────────────────────────────"
echo "  Sign and notarize Sill"
echo "──────────────────────────────────────────────"
echo

# ── 0. Preconditions ─────────────────────────────────────────────────────────
[ -d "Sill.app" ] || die "Sill.app isn't in this folder." \
    "Keep Sill.app and this script together in the same folder."

xcrun --find notarytool >/dev/null 2>&1 || die \
    "notarytool is missing — the Xcode command line tools aren't installed." \
    "Run this, let it finish, then double-click this script again:" \
    "" \
    "    xcode-select --install"

# ── 1. The signing certificate ───────────────────────────────────────────────
CERTS=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application")
if [ -z "$CERTS" ]; then
    echo "You don't have a signing certificate yet. Xcode makes one in four clicks —"
    echo "no website, no downloads."
    echo
    echo "   1.  Xcode  →  Settings…            (⌘,)"
    echo "   2.  Accounts tab → make sure your Apple ID is listed"
    echo "   3.  Click your team → Manage Certificates…"
    echo "   4.  Click  +  (bottom left) → Developer ID Application"
    echo
    echo "That's it. Close Xcode's settings and double-click this script again."
    echo
    read -r -p "Open Xcode now? [Y/n] " OPEN_XC
    case "$OPEN_XC" in
        [Nn]*) ;;
        *) open -a Xcode 2>/dev/null || echo "  (Xcode isn't installed — get it free from the App Store.)" ;;
    esac
    echo
    read -n 1 -s -r -p "Press any key to close."
    exit 1
fi

COUNT=$(echo "$CERTS" | wc -l | tr -d ' ')
if [ "$COUNT" -gt 1 ]; then
    say "You have $COUNT Developer ID certificates. Using the first:"
    echo "$CERTS" | sed 's/^/    /'
    echo
fi

IDENTITY=$(echo "$CERTS" | head -1 | sed -E 's/.*"(.*)"/\1/')
TEAM_ID=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')

if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "$IDENTITY" ]; then
    die "Couldn't read a Team ID out of the certificate name." \
        "The name was: $IDENTITY" \
        "It should end with your ten-character Team ID in brackets."
fi

say "Certificate : $IDENTITY"
say "Team ID     : $TEAM_ID"
echo

# ── 2. Apple credentials — stored in the keychain, first run only ────────────
if ! xcrun notarytool history --keychain-profile "sill-notary" >/dev/null 2>&1; then
    echo "First run — Apple needs your credentials once. They're saved to your"
    echo "keychain, so you won't be asked again."
    echo
    echo "You need an APP-SPECIFIC PASSWORD — your normal Apple password won't work."
    echo "It looks like:  abcd-efgh-ijkl-mnop"
    echo
    read -r -p "Open the page to make one? [Y/n] " OPEN_PW
    case "$OPEN_PW" in
        [Nn]*) echo "  appleid.apple.com → Sign-In and Security → App-Specific Passwords" ;;
        *) open "https://account.apple.com/account/manage" 2>/dev/null
           echo "  → Sign-In and Security → App-Specific Passwords → +" ;;
    esac
    echo
    read -r -p "Apple ID email        : " APPLE_ID
    read -r -p "App-specific password : " APP_PW
    echo
    xcrun notarytool store-credentials "sill-notary" \
        --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW" \
    || die "Apple rejected those credentials." \
           "Check the email, and make sure the password is an APP-SPECIFIC one" \
           "(appleid.apple.com → Sign-In and Security → App-Specific Passwords)."
    echo
fi

# ── 3. Sign ──────────────────────────────────────────────────────────────────
# --options runtime  → hardened runtime, required by the notary service.
# --timestamp        → secure timestamp, also required.
# --identifier       → must match CFBundleIdentifier, or macOS treats the signed
#                      app as a different app and drops its Accessibility grant.
# xattr -cr          → strips quarantine/Finder metadata, which otherwise makes
#                      codesign fail with "resource fork ... not allowed".
say "→ signing"
xattr -cr Sill.app
codesign --force --timestamp --options runtime \
         --identifier app.sill.Sill --sign "$IDENTITY" Sill.app \
|| die "Signing failed." \
       "If the error mentioned errSecInternalComponent, open Keychain Access," \
       "unlock your 'login' keychain, and run this again." \
       "If you are connected over SSH, run this from the Mac's own Terminal."

codesign --verify --strict Sill.app \
    || die "The signature didn't verify. Don't ship this build."

# Prove the hardened runtime actually took. A missing 'runtime' flag here means
# Apple will reject the upload, and it is much cheaper to catch it now than after
# a five-minute round trip.
codesign -dvv Sill.app 2>&1 | grep -q "runtime" \
    || die "Hardened runtime flag is missing after signing." \
           "Apple will reject this. Check that codesign ran with --options runtime."

# ── 4. Submit ────────────────────────────────────────────────────────────────
# ditto, never zip: the zip command does not preserve a code signature.
say "→ uploading to Apple (usually 1–5 minutes)"
rm -f Sill-submit.zip Sill-notarized.zip
ditto -c -k --keepParent Sill.app Sill-submit.zip
xcrun notarytool submit Sill-submit.zip --keychain-profile "sill-notary" --wait \
|| die "Apple rejected the submission." \
       "Get the reason with the submission id printed above:" \
       "" \
       "    xcrun notarytool log <ID> --keychain-profile sill-notary"

# ── 5. Staple, so it opens even with no internet ─────────────────────────────
say "→ attaching the ticket"
xcrun stapler staple Sill.app \
    || die "The app was notarized but the ticket didn't attach. Run this again."
xcrun stapler validate Sill.app >/dev/null 2>&1 \
    || die "The stapled ticket didn't validate. Run this script again."

rm -f Sill-submit.zip
ditto -c -k --keepParent Sill.app Sill-notarized.zip

# ── 6. Final proof ───────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────────"
echo "  Verification"
echo "──────────────────────────────────────────────"
spctl -a -t exec -vv Sill.app 2>&1 | sed 's/^/  /'
codesign -dvv Sill.app 2>&1 | grep -E "Identifier=|TeamIdentifier=|flags=" | sed 's/^/  /'
echo "  stapled ticket: $(xcrun stapler validate Sill.app >/dev/null 2>&1 && echo yes || echo NO)"
echo "──────────────────────────────────────────────"
echo
echo "  All four of these must be true:"
echo "    source=Notarized Developer ID"
echo "    TeamIdentifier=$TEAM_ID    (not 'not set')"
echo "    flags=...(runtime)"
echo "    stapled ticket: yes"
echo
echo "  Done. Send back:  Sill-notarized.zip"
echo
read -n 1 -s -r -p "Press any key to close."

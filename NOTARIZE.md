# Notarizing Sill — instructions for whoever has the Apple Developer account

You're being asked to sign and notarize a small macOS app so it opens on other people's Macs
without the *"Sill is damaged and can't be opened"* warning. It takes about ten minutes, most
of which is Apple's servers thinking.

You do **not** need to understand the app. There is nothing to configure.

## What this app is

A menu-bar utility. Native Swift, no dependencies, no network code. It uses the Accessibility
API to read the current text selection — that's a runtime permission the user grants, not an
entitlement, so there is nothing special to request or justify.

## What you need

1. **A paid Apple Developer account** ($99/yr).
2. **A "Developer ID Application" certificate** installed in your keychain. If you don't have
   one: developer.apple.com → Certificates → **+** → *Developer ID Application* → follow the
   prompts → download and double-click it.
3. **Xcode or the Command Line Tools** — `xcode-select --install`.
4. **An app-specific password.** appleid.apple.com → Sign-In and Security → App-Specific
   Passwords → generate one. Apple rejects your real Apple ID password for this.

## One-time setup

Store your credentials in the keychain so the script can use them:

```bash
xcrun notarytool store-credentials "sill-notary" \
    --apple-id "you@example.com" \
    --team-id "YOURTEAMID" \
    --password "abcd-efgh-ijkl-mnop"
```

Your Team ID is the ten-character code in developer.apple.com → Membership, and it's also in
the brackets after your name in the certificate.

## Run it

```bash
cd sill
./tools/notarize.sh "Developer ID Application: Your Name (YOURTEAMID)" YOURTEAMID
```

Not sure of the exact identity string? Run this and copy it verbatim, brackets included:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

The script builds a universal binary, signs it with the hardened runtime and a secure
timestamp (both of which Apple requires), submits it, waits for the result, staples the
ticket to the app, and re-zips it.

## What you should see at the end

```
status: Accepted
...
build/Sill.app: accepted
source=Notarized Developer ID
```

Then send back **`build/Sill-0.1.0.zip`**. That's the shippable artifact.

## If it fails

**"The signature does not include a secure timestamp"** — you're offline, or Apple's
timestamp server is briefly down. Retry.

**"Team is not yet configured for notarization"** — your account is new; Apple takes up to
about an hour after enrolment. Wait and retry.

**status: Invalid** — get the detail with the submission ID it prints:

```bash
xcrun notarytool log <SUBMISSION-ID> --keychain-profile "sill-notary"
```

**"errSecInternalComponent"** — the keychain won't let `codesign` use the private key. Unlock
the login keychain and try again, or run the script from Terminal rather than over SSH.

## Notes for the person receiving this back

The stapled `.zip` is what goes on GitHub Releases. Once it's notarized:

- Users can download and open it with no warning and no `xattr` command.
- The README's "Install" section should drop the quarantine workaround.
- More importantly, the app's identity becomes stable — **the Accessibility permission will
  survive app updates**, instead of being silently revoked on every release. That's the real
  reason to do this.

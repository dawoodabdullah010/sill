SILL — sign and notarize
========================

Double-click  notarize.command  and follow it. That's the whole job.

It checks what's missing, tells you exactly what to do, and offers to open
the right window for you. Running it again after a failure is always safe.

About ten minutes, most of it waiting on Apple.


THE TWO THINGS IT WILL ASK FOR
------------------------------

1. A signing certificate.

   Xcode makes one in four clicks — no website, no downloads:

       Xcode → Settings… (⌘,) → Accounts
             → click your team → Manage Certificates…
             → click + (bottom left) → Developer ID Application

   The script offers to open Xcode for you if you don't have one yet.

2. An app-specific password (Apple rejects your normal password here).

   The script offers to open the page. Sign-In and Security →
   App-Specific Passwords → +. Looks like: abcd-efgh-ijkl-mnop

   Asked once, then saved to your keychain. Never again.


WHEN IT'S DONE
--------------

It prints a verification block. All four lines must be true:

    source=Notarized Developer ID
    TeamIdentifier=<your team id>      (not "not set")
    flags=...(runtime)
    stapled ticket: yes

Then send back the file called:

    Sill-notarized.zip


IF SOMETHING GOES WRONG
-----------------------

The script prints what to do. If it's not obvious, just send back what
it printed.

Two that aren't the script's fault:

  "Team is not yet configured for notarization"
        Your developer account is brand new. Apple takes up to an hour
        after you enrol. Wait, run it again.

  "errSecInternalComponent"
        Open Keychain Access, unlock the "login" keychain, run it again.


WHAT THE APP IS
---------------

A small menu-bar note-taker. Native Swift, no dependencies, no network
code — nothing is uploaded anywhere. Open source, MIT licensed.

It uses the macOS Accessibility API to read selected text. That's a
permission the user grants at runtime, not an entitlement, so there's
nothing to request or justify on your account.

Notarizing is just Apple scanning it for malware. It won't come back
on you.

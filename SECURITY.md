# Security Policy

## Reporting a vulnerability

Please report security issues privately, not as a public issue.

Use GitHub's [private vulnerability reporting](https://github.com/dawoodabdullah010/sill/security/advisories/new)
— Security tab → Report a vulnerability. It goes straight to the maintainer and stays hidden
until there's a fix.

Include what you did, what happened, and what you expected. A proof of concept helps but isn't
required. I'll acknowledge within 72 hours and keep you updated until it's resolved. If you'd
like credit in the release notes, say so; otherwise reports stay anonymous.

## Supported versions

Sill is pre-1.0. Only the latest commit on `main` is supported. Fixes ship as a new release
rather than being backported.

## What Sill can actually do

Worth knowing before you look, because it narrows the attack surface a great deal.

**No network code exists in this repository.** Not "we don't collect data" — there is no code
here capable of making a request. You can verify it in one command:

```bash
grep -rniE 'URLSession|NSURLConnection|CFNetwork|NWConnection|socket|http' Sources/
```

The only `URL`s are `file://` paths to your notes, the `x-apple.systempreferences:` link that
opens System Settings, and URLs you captured yourself — opened in your browser only when you
click them.

**There are no dependencies.** `swift build` fetches nothing, so there is no third-party code
and no supply chain to compromise.

**Sill asks for Accessibility, and that permission is powerful.** With it granted, Sill can
read the text you have selected in other apps and synthesize keystrokes (a `⌘C` to capture, a
`⌘V` to send back). That is the entire reason it's requested, and everything it's used for is
in [`Sources/Sill/Capture.swift`](Sources/Sill/Capture.swift). Accessibility is optional — Sill
works without it by reading the clipboard after you press `⌘C` yourself.

**Your notes are plain files on your disk**, at `~/Library/Application Support/Sill/`, with
normal user permissions. Sill has no sandbox entitlements and no privileged helper.

## Things that are known, and deliberate

Listing these because "it's not a vulnerability, it's a design choice" should be stated up
front rather than argued after the fact.

- **Notes are stored unencrypted.** They're markdown files you're meant to open in other
  editors. Anything with access to your user account can read them. Use FileVault.
- **Captured text keeps its source app and URL** in an HTML comment beside it, so "back to
  source" works. If you share the file, you share that.
- **Releases before the first notarized build are ad-hoc signed**, which means macOS can't
  verify the author. Build from source if that matters to you — the README explains how.

## Scope

In scope: anything in `Sources/`, `tools/`, and `build.sh`.

Out of scope: macOS itself, issues that require an attacker to already have code execution as
your user, and the deliberate design choices listed above.

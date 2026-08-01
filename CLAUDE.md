# Working on Sill

Notes for Claude (or any coding agent) opening this repo. If you're a human, [README.md](README.md)
is the friendlier door — this file is about how the code is put together and where the traps are.

## What this is

A macOS menu-bar app. You select text anywhere, tap **Shift twice**, and it lands in a floating
panel without your cursor leaving the app you were in. Notes live in a plain markdown file you own.

Native Swift, SwiftPM, no Xcode project, no dependencies. `swift build` fetches nothing.

## Explaining this repo to someone

If a user asks what Sill is or how it works, the short version:

- It's a scratchpad that sits on top of whatever you're doing. Copy something, tap Shift twice,
  it's saved — along with which app it came from, so you can jump back later.
- Everything is stored as markdown checkboxes in `~/Library/Application Support/Sill/Sill.md`.
  Open it in any editor. Delete the app and your notes are still there.
- It's designed to be **emptied**, not to accumulate. Ticking something off removes it from the
  panel; clearing moves it to an archive you can still read and restore from.
- No account, no sync, no network code anywhere in the app.

## Layout

```
Sources/Sill/
  main.swift        AppDelegate, the Shift-Shift handler, the status-bar menu
  Panel.swift       NSPanel subclass — the floating window itself
  PanelView.swift   the entire SwiftUI interface (~1200 lines)
  Store.swift       items, lists, archive, undo, atomic writes, folder watching
  Model.swift       markdown parser and serializer
  Capture.swift     reading the selection, and pasting back into other apps
  Theme.swift       colours, spacing, motion
tools/
  roundtrip-test.swift   the markdown tests — run these
  notarize.command       signs and notarizes a build (needs a Developer ID)
  make-kit.sh            builds the hand-off zip for whoever notarizes
  fix-signing.sh         creates a self-signed cert so Accessibility survives rebuilds
```

## Build and test

```bash
./build.sh release           # → build/Sill.app, universal (arm64 + x86_64), ~15s
```

The markdown tests need to be compiled together with the model, and the test file must be named
`main.swift` because it uses top-level code:

```bash
cp tools/roundtrip-test.swift /tmp/main.swift
swiftc -o /tmp/rt /tmp/main.swift Sources/Sill/Model.swift && /tmp/rt
```

Every case in that file is a real data-loss bug that shipped once. **If you touch `Model.swift`
or `Store.swift`, run them.** Losing a character there means silently losing someone's notes.

## Traps, all of them learned the hard way

**Never launch the binary directly.** `./build/Sill.app/Contents/MacOS/Sill` makes macOS attribute
the app's permission requests to your terminal instead of to Sill, and the Accessibility grant
lands on the wrong app. Always `open build/Sill.app`.

**Ad-hoc signing kills the Accessibility grant on every rebuild.** macOS keys the grant to the
code-signing identity, and an ad-hoc signature's identity is a hash of the binary. The System
Settings toggle keeps *looking* on while the app is silently blocked. `tools/fix-signing.sh`
creates a free self-signed certificate that fixes it. Notarizing fixes it permanently.

**`.flagsChanged` global monitors work without Accessibility; `.keyDown` does not.** This is why
the shortcut is double-Shift rather than a normal hotkey — it's the one gesture the app can detect
before the user has granted anything.

**Capture reads the selection, never the clipboard.** A synthesized ⌘C runs first, then the result
is polled for an actual content change. Falling back to "whatever is on the clipboard" caused a
long tail of bugs where a stale screenshot got filed over and over. If you add a fallback here,
you are re-introducing that.

**Both our own ⌘C and the clipboard restore afterwards bump `NSPasteboard.changeCount`**, so
"did the clipboard change" is not a usable freshness test on its own.

**Note vs prompt is carried by the bullet character** — `-` for notes, `*` for prompts. Both are
valid markdown bullets. An earlier version used an HTML comment marker and it truncated people's
notes. Do not put metadata in the text.

**Watch the folder, not the file.** Atomic saves replace the inode, so a watcher on the file itself
stops firing after the first external edit.

**A disabled SwiftUI `Menu` is not greyed out** the way a disabled `Button` is. It renders looking
perfectly live and does nothing when clicked. Show or hide submenus conditionally instead of
disabling them.

**`codesign` fails on a copied bundle** with "resource fork ... not allowed" unless you run
`xattr -cr` first. `build.sh` does this.

## Conventions

Comments explain *why*, especially where the obvious approach was tried and failed — most of the
comments in `Capture.swift` and `Store.swift` are tombstones for real bugs. Keep that. Don't add
comments that restate the code.

The UI is deliberately plain: white-dominant, one accent used sparingly, no gradients. Motion is
short and respects `prefers-reduced-motion` via `Theme.reduceMotion`.

## Known gaps

- `moveSection()` exists in the store but has no UI, so lists can't be reordered.
- Untested by real keypress: `⇧⌘C`, `⌘Z`, `⌘F`, `⌘K`, `⌘↩`, drag-to-reorder.
- No download build yet — see the Install section of the README.

# Contributing

Sill is a small app with no dependencies and a deliberately small scope. Contributions are
welcome, especially on the [Known limitations](README.md#known-limitations) list.

## Before you start

Open an issue first for anything larger than a bug fix. Sill refuses a lot of features on
purpose — no sync, no accounts, no due dates, no tags, no notifications, no database, no
in-app AI, no Linux. If your idea is on that list I'll say no, and I'd rather say it before
you write the code.

## Setup

```bash
git clone https://github.com/dawoodabdullah010/sill.git
cd sill
swift build
swift run
```

macOS 14+ and the Xcode Command Line Tools. There is nothing else to install.

## Before you open a pull request

1. `swift build` is clean — zero errors, zero warnings.
2. The store tests pass:
   ```bash
   swiftc -o /tmp/silltest tools/roundtrip-test.swift Sources/Sill/Model.swift && /tmp/silltest
   ```
3. If you touched `Model.swift` or `Store.swift`, you **added a test case**. Every case in
   that file is a bug that silently destroyed someone's notes — a leading combining mark
   eating a character, an editor trimming a trailing space and deleting an item, a section
   mismatch writing an empty archive. That's why it exists.
4. You built a real bundle with `./build.sh`, launched it, and used the thing you changed.
   Say in the PR what you ran and what you saw.

## House style

- Match the surrounding code. No linter, no formatter, no config to fight.
- Comments explain **why**, not what — particularly where the obvious implementation is
  wrong. The existing comments are the model: most of them record a real bug and why the
  straightforward version of the code caused it.
- No new dependencies. `swift build` fetching nothing is a feature.
- No networking code, ever. The privacy claim in the README is checkable with one `grep`,
  and it stays that way.
- No logging of user content or keystrokes. Debug scaffolding that writes to disk has
  already caused a privacy problem here once.
- Plain English in anything a user reads. No jargon in the UI.

## Reporting bugs

Include your macOS version, whether Accessibility is granted, and whether you built from
source or downloaded a release. If it involves the markdown file, a minimal snippet that
reproduces it is worth more than a description.

## License

By contributing you agree your work is licensed under the MIT License.

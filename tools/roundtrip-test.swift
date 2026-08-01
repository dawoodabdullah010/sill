// Round-trip test for the markdown store.
// Run:  swift tools/roundtrip-test.swift Sources/Sill/Model.swift
//
// Losing a character here means silently losing someone's notes, so this is the
// one part of Sill that gets real tests.

import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func roundTrip(_ items: [Item], _ sections: [String], _ name: String) {
    let text = MarkdownFile.serialize(items: items, sections: sections)
    let back = MarkdownFile.parse(text)

    check("\(name): count", back.items.count == items.count,
          "expected \(items.count), got \(back.items.count)")
    check("\(name): sections", back.sections == sections,
          "expected \(sections), got \(back.sections)")

    for (a, b) in zip(items, back.items) {
        check("\(name): text \"\(a.title.prefix(20))\"", a.text == b.text,
              "\(a.text.debugDescription) != \(b.text.debugDescription)")
        check("\(name): kind", a.kind == b.kind)
        check("\(name): done", a.done == b.done)
        check("\(name): section", a.section == b.section)
        check("\(name): source", a.source == b.source,
              "\(String(describing: a.source)) != \(String(describing: b.source))")
    }
}

print("markdown round trip")

roundTrip([Item(text: "a plain note", section: "Inbox")], ["Inbox"], "simple")

roundTrip([
    Item(text: "a note", kind: .note, done: false, section: "Research"),
    Item(text: "a prompt", kind: .prompt, done: false, section: "Research"),
    Item(text: "a finished prompt", kind: .prompt, done: true, section: "Research"),
], ["Research"], "kinds and done")

roundTrip([
    Item(text: "line one\nline two\nline three", section: "Inbox"),
], ["Inbox"], "multiline")

roundTrip([
    Item(text: "first", section: "Alpha"),
    Item(text: "second", section: "Beta"),
], ["Alpha", "Beta"], "two sections")

// Text that looks like our own markup must survive untouched.
roundTrip([
    Item(text: "- [ ] not really a checkbox", section: "Inbox"),
    Item(text: "* [x] nor is this", section: "Inbox"),
    Item(text: "# not really a heading", section: "Inbox"),
    Item(text: "ends with a marker <!--p-->", kind: .note, section: "Inbox"),
    Item(text: "  leading spaces kept", section: "Inbox"),
], ["Inbox"], "adversarial")

// Provenance must survive, including text that imitates the provenance line.
roundTrip([
    Item(text: "from a chat", section: "Inbox",
         source: Source(appName: "ChatGPT", bundleID: "com.openai.chat")),
    Item(text: "app with no bundle id", section: "Inbox",
         source: Source(appName: "Some App", bundleID: nil)),
    Item(text: "deep link to an exact page", section: "Inbox",
         source: Source(appName: "Chrome", bundleID: "com.google.Chrome",
                        url: "https://claude.ai/chat/abc-123?x=1")),
    Item(text: "url but no bundle id", section: "Inbox",
         source: Source(appName: "Arc", bundleID: nil, url: "https://example.com/a")),
    Item(text: "<!-- from: Fake | com.fake -->", section: "Inbox", source: nil),
    Item(text: "no source at all", section: "Inbox", source: nil),
], ["Inbox"], "provenance")

// A prompt and a note with identical text must stay distinguishable.
roundTrip([
    Item(text: "same words", kind: .note, section: "Inbox"),
    Item(text: "same words", kind: .prompt, section: "Inbox"),
], ["Inbox"], "same text different kind")

roundTrip([
    Item(text: "emoji 🪟 and “smart quotes” and\ttabs", section: "Inbox"),
], ["Inbox"], "unicode")

// Regression cases from the adversarial review. Each of these lost user data.

// dropFirst(6) counts grapheme clusters, so a leading combining mark merged into
// the padding space and the first character vanished.
roundTrip([
    Item(text: "\u{0301}hello", section: "Inbox"),          // combining acute
    Item(text: "\u{064E}\u{0645}\u{0631}", section: "Inbox"), // Arabic with harakat
    Item(text: "\u{200D}x", section: "Inbox"),               // zero-width joiner
], ["Inbox"], "leading combining marks")

// Items whose first line is empty must not serialize with a trailing space, or an
// editor that trims trailing whitespace deletes them and merges the body upward.
roundTrip([
    Item(text: "\nsecond line only", section: "Inbox"),
    Item(text: "", section: "Inbox"),
], ["Inbox"], "empty first line")

print("\nparser hardening")

// An editor stripped the trailing space: the item must survive, not be swallowed.
do {
    let trimmed = "# Inbox\n\n- [ ] first\n- [ ]\n  continuation of the second\n"
    let out = MarkdownFile.parse(trimmed)
    check("trimmed bullet keeps two items", out.items.count == 2,
          "got \(out.items.count): \(out.items.map(\.text))")
    check("continuation stays with its own item",
          out.items.last?.text == "\ncontinuation of the second",
          String(describing: out.items.last?.text))
}

// CRLF must not leak \r into section names or item text.
do {
    let crlf = "# Inbox\r\n\r\n- [ ] note one\r\n  cont\r\n"
    let out = MarkdownFile.parse(crlf)
    check("CRLF section name clean", out.sections == ["Inbox"], "\(out.sections)")
    check("CRLF item text clean", out.items.first?.text == "note one\ncont",
          String(describing: out.items.first?.text))
}


// Multi-paragraph captures: an editor that strips trailing whitespace turns the
// "  " separator line into "", which used to fuse every paragraph together.
roundTrip([
    Item(text: "para one\n\npara two", section: "Inbox"),
    Item(text: "a\n\n\nb", section: "Inbox"),
], ["Inbox"], "blank lines inside an item")

do {
    let trimmed = "# Inbox\n\n- [ ] para one\n\n  para two\n"
    let out = MarkdownFile.parse(trimmed)
    check("trimmed blank line keeps one item", out.items.count == 1, "got \(out.items.count)")
    check("paragraph break survives trimming",
          out.items.first?.text == "para one\n\npara two",
          String(describing: out.items.first?.text))
}

print("\narchive serialization")

// The archive bug: items keep their own section, but `serialize` only emits items whose
// section is in the list it was given. Passing ["Archive"] with items still saying
// "Inbox" wrote an EMPTY file and destroyed every cleared item.
do {
    let cleared = [
        Item(text: "finished one", done: true, section: "Inbox"),
        Item(text: "finished two", done: true, section: "Work"),
    ]
    // Wrong way — what the bug did.
    let bad = MarkdownFile.serialize(items: cleared, sections: ["Archive"])
    check("mismatched section serializes to nothing (the bug)",
          MarkdownFile.parse(bad).items.isEmpty)

    // Right way — re-home into the section being written.
    let rehomed = cleared.map { item -> Item in
        var copy = item; copy.section = "Archive"; return copy
    }
    let good = MarkdownFile.serialize(items: rehomed, sections: ["Archive"])
    let back = MarkdownFile.parse(good)
    check("re-homed archive keeps every item", back.items.count == 2,
          "got \(back.items.count)")
    check("archive text survives", back.items.first?.text == "finished one")
    check("archive keeps done state", back.items.allSatisfy(\.done))
}

print("\nhand-written markdown survives")

// Opening the app used to silently delete anything it didn't recognise — paragraphs,
// sub-headings, quotes. For "plain markdown you own" that made the promise untrue.
do {
    let handWritten = """
    # Inbox

    A paragraph I typed in Obsidian.

    - [ ] a real item
      continued

    ## A sub-heading I added

    > a quote I added
    """
    let parsed = MarkdownFile.parse(handWritten)
    check("item still parsed", parsed.items.count == 1)
    check("foreign lines captured", parsed.foreign.count == 3,
          "got \(parsed.foreign.count): \(parsed.foreign.map(\.line))")

    let rewritten = MarkdownFile.serialize(items: parsed.items,
                                           sections: parsed.sections,
                                           foreign: parsed.foreign)
    for needle in ["A paragraph I typed in Obsidian.",
                   "## A sub-heading I added",
                   "> a quote I added"] {
        check("kept: \(needle.prefix(22))", rewritten.contains(needle))
    }
    check("item kept too", rewritten.contains("- [ ] a real item"))
}

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

import Foundation

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum ItemKind: String {
    case note      // something you captured and want to keep
    case prompt    // something you typed and intend to run
}

/// Where an item came from, so you can get back to it.
///
/// `url` is the actual page — the specific conversation, not just the app — when the
/// source was a browser and we could read it. That's the difference between "go to
/// Chrome" and "go back to that exact chat".
struct Source: Equatable {
    var appName: String
    var bundleID: String?
    var url: String?

    /// True when clicking will land you on the exact thing, not merely the right app.
    var isExact: Bool { url != nil }

    var encoded: String {
        var fields = [appName, bundleID ?? "", url ?? ""]
        while fields.count > 1, fields.last?.isEmpty == true { fields.removeLast() }
        return fields.joined(separator: " | ")
    }

    static func decode(_ raw: String) -> Source {
        let parts = raw.components(separatedBy: " | ").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return Source(appName: parts.first ?? raw,
                      bundleID: parts.count > 1 ? parts[1].nilIfEmpty : nil,
                      url: parts.count > 2 ? parts[2].nilIfEmpty : nil)
    }
}

struct Item: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var kind: ItemKind = .note
    var done: Bool = false
    var section: String
    var source: Source? = nil
    var createdAt: Date? = nil
    var completedAt: Date? = nil

    /// A URL sitting in the captured text itself — paste an X link and it stays clickable.
    /// Needs no permission, unlike reading the page you captured *from*.
    /// Cached per text. Selecting a card re-renders every row, and each row reads this
    /// three times — without the cache that meant re-scanning every note on every click,
    /// which is exactly the "clicking a note is delayed" symptom.
    var linkInText: URL? {
        if let cached = Self.linkCache[text] { return cached }
        let found = Self.detectLink(in: text)
        Self.linkCache[text] = found
        if Self.linkCache.count > 500 { Self.linkCache.removeAll() }
        return found
    }

    private static func detectLink(in text: String) -> URL? {
        guard let detector = linkDetector else { return nil }
        // A link worth showing is at the start of a capture, not buried in an essay.
        // Scanning the whole body of a 50KB paste costs far more than it can ever return.
        let head = String(text.prefix(400))
        let range = NSRange(head.startIndex..., in: head)
        guard let url = detector.firstMatch(in: head, range: range)?.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"      // never mailto: — it hijacked
        else { return nil }                              // the back-to-source button
        return url
    }

    /// Built once. `NSDataDetector` is expensive to construct.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    nonisolated(unsafe) private static var linkCache: [String: URL?] = [:]

    /// Anything clickable: the pasted link first, then where it was captured from.
    var openableURL: URL? {
        linkInText ?? source?.url.flatMap(URL.init(string:))
    }

    /// "6d", "3h", "now" — the short right-hand label.
    func age(now: Date = Date()) -> String? {
        guard let createdAt else { return nil }
        let seconds = now.timeIntervalSince(createdAt)
        switch seconds {
        case ..<60:     return "now"
        case ..<3600:   return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default:        return "\(Int(seconds / 86_400))d"
        }
    }

    /// Items older than a week sink into the OLDER group.
    func isOlder(now: Date = Date()) -> Bool {
        guard let createdAt else { return false }   // hand-written items are never stale
        return now.timeIntervalSince(createdAt) > 7 * 86_400
    }

    /// The attachment path when this item is a markdown image — `![alt](attachments/x.png)`.
    var imagePath: String? {
        guard let open = text.firstIndex(of: "("),
              text.hasPrefix("!["),
              text.hasSuffix(")")
        else { return nil }
        let path = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        return path.hasSuffix(".png") || path.hasSuffix(".jpg") ? path : nil
    }

    var isImage: Bool { imagePath != nil }

    /// First line only — what the card shows when collapsed.
    var title: String {
        text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }
}

/// Markdown on disk, so the store is readable and editable outside Sill.
///
///     # Research
///
///     - [ ] a captured note
///       continuation lines are indented two spaces
///     * [x] a finished prompt
///
/// Notes use `-`, prompts use `*`. Markdown treats the two bullet characters as
/// identical, so both render as ordinary checkboxes in Obsidian or on GitHub —
/// but the distinction survives a round trip.
///
/// The bullet character carries the meaning precisely so that nothing has to be
/// embedded in the text. An earlier version appended an HTML comment as a marker;
/// a note whose text happened to end with that comment was silently reclassified
/// and truncated. There is no such failure mode here, because the user's text is
/// never inspected for markup.
enum MarkdownFile {
    private static let noteBullet: Character = "-"
    private static let promptBullet: Character = "*"
    private static let metaPrefix = "<!-- sill: "
    private static let legacyPrefix = "<!-- from: "   // files written before timestamps

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `<!-- sill: c=… | d=… | app=… | bundle=… | url=… -->`
    /// Pipe-separated so app names with spaces survive. Only present fields are written,
    /// so an item with no metadata emits no comment line and a hand-written file
    /// round-trips byte-identically.
    static func encodeMeta(_ item: Item) -> String? {
        var parts: [String] = []
        if let c = item.createdAt   { parts.append("c=\(iso.string(from: c))") }
        if let d = item.completedAt { parts.append("d=\(iso.string(from: d))") }
        if let s = item.source {
            parts.append("app=\(s.appName)")
            if let b = s.bundleID { parts.append("bundle=\(b)") }
            if let u = s.url      { parts.append("url=\(u)") }
        }
        guard !parts.isEmpty else { return nil }
        return "\(metaPrefix)\(parts.joined(separator: " | ")) -->"
    }

    static func decodeMeta(_ raw: String) -> (Date?, Date?, Source?)? {
        // Legacy form: "<!-- from: App | bundle | url -->"
        if raw.hasPrefix(legacyPrefix), raw.hasSuffix("-->") {
            let body = raw.dropFirst(legacyPrefix.count).dropLast(3)
            return (nil, nil, Source.decode(String(body).trimmingCharacters(in: .whitespaces)))
        }
        guard raw.hasPrefix(metaPrefix), raw.hasSuffix("-->") else { return nil }

        let body = String(raw.dropFirst(metaPrefix.count).dropLast(3))
            .trimmingCharacters(in: .whitespaces)
        var created: Date?, completed: Date?
        var app: String?, bundle: String?, url: String?

        for field in body.components(separatedBy: " | ") {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = String(field[field.startIndex..<eq])
            let value = String(field[field.index(after: eq)...])
            switch key {
            case "c":      created = iso.date(from: value)
            case "d":      completed = iso.date(from: value)
            case "app":    app = value
            case "bundle": bundle = value.nilIfEmpty
            case "url":    url = value.nilIfEmpty
            default:       break
            }
        }
        let source = app.map { Source(appName: $0, bundleID: bundle, url: url) }
        return (created, completed, source)
    }

    static func serialize(items: [Item], sections: [String], foreign: [Foreign] = []) -> String {
        var out: [String] = []
        for section in sections {
            out.append("# \(section)")
            out.append("")

            // Lines the user wrote themselves, put back at the position they held.
            let mine = foreign.filter { $0.section == section }
            var seen = 0
            func emitForeign(upTo count: Int) {
                for line in mine where line.afterItems == count {
                    out.append(line.line)
                    out.append("")
                }
            }
            emitForeign(upTo: 0)

            for item in items where item.section == section {
                // Provenance goes on its own line *before* the item. User text is always
                // either bullet-prefixed or two-space indented, so a bare comment line
                // can only ever have been written by us — nothing to escape.
                if let meta = encodeMeta(item) {
                    out.append(meta)
                }
                let bullet = item.kind == .prompt ? promptBullet : noteBullet
                let box = item.done ? "x" : " "
                let lines = item.text.components(separatedBy: "\n")
                let first = lines.first ?? ""
                // No trailing space when the first line is empty: editors that strip
                // trailing whitespace would turn "- [ ] " into "- [ ]" and the item
                // would be dropped on the next read, taking its continuation lines
                // with it into the previous item.
                out.append(first.isEmpty ? "\(bullet) [\(box)]" : "\(bullet) [\(box)] \(first)")
                for line in lines.dropFirst() {
                    out.append("  \(line)")
                }
                seen += 1
                emitForeign(upTo: seen)
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// Matches one item line by literal prefix.
    ///
    /// Matching literals rather than counting characters matters: `dropFirst(6)` counts
    /// *grapheme clusters*, and a body starting with a combining mark (vocalised Arabic
    /// or Hebrew, Devanagari, a leading ZWJ in an emoji sequence) merges into the
    /// preceding space to form a single cluster — so the first character of the user's
    /// text was being silently eaten on every round trip.
    private static func parseItemLine(_ raw: String) -> (String, Bool, ItemKind)? {
        for (bullet, kind) in [(noteBullet, ItemKind.note), (promptBullet, ItemKind.prompt)] {
            for (box, done) in [(" ", false), ("x", true)] {
                if let body = dropScalarPrefix("\(bullet) [\(box)] ", from: raw) {
                    return (body, done, kind)
                }
                // An editor that trims trailing whitespace leaves the empty-bodied form.
                if raw == "\(bullet) [\(box)]" {
                    return ("", done, kind)
                }
            }
        }
        return nil
    }

    /// Prefix match over unicode scalars rather than characters.
    ///
    /// `hasPrefix` and `dropFirst` both work in grapheme clusters. When the body begins
    /// with a combining mark, that mark joins the prefix's trailing space into a single
    /// cluster — so `hasPrefix("- [ ] ")` is false and `dropFirst(6)` eats a real
    /// character. Scalars don't combine, so the boundary stays where we put it.
    private static func dropScalarPrefix(_ prefix: String, from raw: String) -> String? {
        let body = Array(raw.unicodeScalars)
        let head = Array(prefix.unicodeScalars)
        guard body.count >= head.count else { return nil }
        for i in head.indices where body[i] != head[i] { return nil }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: body[head.count...])
        return String(view)
    }

    static func parse(_ text: String) -> (items: [Item], sections: [String], foreign: [Foreign]) {
        var items: [Item] = []
        var sections: [String] = []
        var section = "Inbox"
        var pendingSource: Source?
        var pendingCreated: Date?
        var pendingCompleted: Date?
        var foreign: [Foreign] = []
        var pendingBlanks = 0

        // Normalise line endings first. A file touched by a Windows or cross-platform
        // editor otherwise leaves a trailing \r on every line — and since CharacterSet
        // .whitespaces does not contain \r, "Inbox\r" != "Inbox" and the next save
        // appends a second, visually identical section.
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for raw in normalised.components(separatedBy: "\n") {
            if raw.hasPrefix("# ") {
                section = String(raw.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !section.isEmpty && !sections.contains(section) { sections.append(section) }
                continue
            }

            if let (created, completed, source) = decodeMeta(raw) {
                pendingCreated = created
                pendingCompleted = completed
                pendingSource = source
                continue
            }

            if let (body, done, kind) = parseItemLine(raw) {
                if !sections.contains(section) { sections.append(section) }
                items.append(Item(text: body,
                                  kind: kind,
                                  done: done,
                                  section: section,
                                  source: pendingSource,
                                  createdAt: pendingCreated,
                                  completedAt: pendingCompleted))
                pendingSource = nil
                pendingCreated = nil
                pendingCompleted = nil
                continue
            }

            // Two-space indent continues the previous item's text.
            if raw.hasPrefix("  "), !items.isEmpty {
                // Flush any blank lines we were holding — they were paragraph breaks
                // inside this item, not gaps between items.
                if pendingBlanks > 0 {
                    items[items.count - 1].text += String(repeating: "\n", count: pendingBlanks)
                    pendingBlanks = 0
                }
                items[items.count - 1].text += "\n" + String(raw.dropFirst(2))
                continue
            }

            // A blank line is ambiguous: it separates items, but it is ALSO what an editor
            // leaves behind when it strips the trailing spaces from an empty continuation
            // line. Hold it and decide when we see what comes next — otherwise every
            // paragraph break inside a long capture is destroyed on the next read.
            if raw.trimmingCharacters(in: .whitespaces).isEmpty, !items.isEmpty {
                pendingBlanks += 1
                continue
            }
            pendingBlanks = 0

            // Anything else is a line a human wrote in the file themselves — a paragraph,
            // a sub-heading, a quote. Keep it, anchored to where it sat, and write it back
            // out in place. Dropping it made "plain markdown you own" untrue: opening the
            // app silently deleted whatever it didn't recognise.
            //
            // Blank lines are structure, not content: serialize puts its own spacing back,
            // so keeping them would multiply the gaps on every save.
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            foreign.append(Foreign(section: section, afterItems: items.count, line: raw))
        }

        if sections.isEmpty { sections = ["Inbox"] }
        return (items, sections, foreign)
    }
}

/// A line Sill doesn't own, remembered so it can be written back exactly where it was.
struct Foreign: Equatable {
    var section: String
    /// How many items had been seen in the file when this line appeared.
    var afterItems: Int
    var line: String
}

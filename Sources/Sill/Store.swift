import Foundation
import SwiftUI

/// Owns the items and writes them to disk. One markdown file, atomic writes.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var sections: [String] = ["Inbox"]

    /// `~/Library/Application Support/Sill/`, **not** `~/Documents`.
    ///
    /// Documents is TCC-protected: macOS runs an access check on every write, so a store
    /// that saves on each change makes the system ask for permission over and over.
    /// Application Support needs no permission at all. "Open Notes Folder" in the menu
    /// keeps it one click away, and the file is still plain markdown you own.
    /// Defaults to Application Support, but the user can point it anywhere — an Obsidian
    /// vault, a git repo, a synced folder. That's the whole point of plain markdown.
    static let folderKey = "SillStoreFolder"

    static var folder: URL {
        if let saved = UserDefaults.standard.string(forKey: folderKey), !saved.isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return defaultFolder
    }

    static let defaultFolder = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sill", isDirectory: true)

    static var file: URL { folder.appendingPathComponent("Sill.md") }

    /// Point the store at a new folder. Copies the existing notes across rather than
    /// abandoning them, and never overwrites a file already there.
    func relocate(to newFolder: URL) -> String? {
        let fm = FileManager.default
        let target = newFolder.appendingPathComponent("Sill.md")
        do {
            try fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) {
                let text = MarkdownFile.serialize(items: items, sections: sections)
                try text.write(to: target, atomically: true, encoding: .utf8)
            }
            UserDefaults.standard.set(newFolder.path, forKey: Self.folderKey)
            load()
            loadArchive()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Where earlier builds kept it. Contents are copied across once, and the original is
    /// left untouched — never move someone's notes out from under them.
    private static let legacyFolder = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Sill", isDirectory: true)

    init() {
        migrateFromDocumentsIfNeeded()
        load()
        loadArchive()
        // Swept here rather than on delete: by launch the undo stack is empty, so no
        // pending undo can need a file we just unlinked.
        sweepOrphanedAttachments()
        startWatchingFolder()
    }

    private func migrateFromDocumentsIfNeeded() {
        let fm = FileManager.default
        let legacyFile = Self.legacyFolder.appendingPathComponent("Sill.md")
        guard fm.fileExists(atPath: legacyFile.path),
              !fm.fileExists(atPath: Self.file.path) else { return }
        do {
            try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try fm.copyItem(at: legacyFile, to: Self.file)
            let legacyAttachments = Self.legacyFolder.appendingPathComponent("attachments")
            if fm.fileExists(atPath: legacyAttachments.path) {
                try? fm.copyItem(at: legacyAttachments, to: Self.attachments)
            }
        } catch {
            NSLog("Sill: migration skipped — \(error.localizedDescription)")
        }
    }

    // MARK: - Undo

    private struct Snapshot { let items: [Item]; let sections: [String]; let label: String }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let undoLimit = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var lastUndoLabel: String? { undoStack.last?.label }

    /// Snapshot the whole store before a mutation.
    ///
    /// A snapshot rather than a command-with-inverse: the state is an array of value types,
    /// copies are cheap through copy-on-write, and there is no way to get the inverse of a
    /// cross-section move subtly wrong.
    private func checkpoint(_ label: String) {
        undoStack.append(Snapshot(items: items, sections: sections, label: label))
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    @discardableResult
    func undo() -> String? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(Snapshot(items: items, sections: sections, label: entry.label))
        items = entry.items
        sections = entry.sections
        save()
        return entry.label
    }

    @discardableResult
    func redo() -> String? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(Snapshot(items: items, sections: sections, label: entry.label))
        items = entry.items
        sections = entry.sections
        save()
        return entry.label
    }

    // MARK: - Reading

    func items(in section: String) -> [Item] {
        items.filter { $0.section == section }
    }

    func matching(_ query: String) -> [Item] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Writing

    /// A line beginning `# ` creates (or switches to) a section instead of adding an item.
    /// This is the only way sections are made — there is no section UI.
    ///
    /// `allowSectionSyntax` is false by default and true only from the composer. Captured
    /// text is never interpreted: selecting a README or a ChatGPT answer that begins with
    /// a markdown heading used to create a garbage section and silently discard the capture.
    @discardableResult
    func add(_ raw: String,
             kind: ItemKind,
             to section: String,
             source: Source? = nil,
             allowSectionSyntax: Bool = false) -> String {
        // Newlines only. Trimming all whitespace strips the leading indent of the first
        // line, which is exactly wrong when capturing an indented code block.
        let text = raw.trimmingCharacters(in: .newlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return section }

        if allowSectionSyntax, text.hasPrefix("# ") {
            let name = String(text.dropFirst(2))
                .components(separatedBy: "\n").first?          // a section is one line
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return section }
            if !sections.contains(name) {
                checkpoint("New list \(name)")
                sections.append(name)
            }
            save()
            return name
        }

        checkpoint("Add")
        if !sections.contains(section) { sections.append(section) }
        items.append(Item(text: text, kind: kind, section: section,
                          source: source, createdAt: Date()))
        save()
        return section
    }

    /// With several selected, this sets them all to the same state rather than flipping
    /// each independently — a mixed selection flipping into a different mixed selection
    /// is the "it bugs out" behaviour.
    func toggleDone(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        checkpoint(ids.count == 1 ? "Mark done" : "Mark \(ids.count) done")

        let anyUndone = items.contains { ids.contains($0.id) && !$0.done }
        for i in items.indices where ids.contains(items[i].id) {
            items[i].done = anyUndone
            items[i].completedAt = anyUndone ? Date() : nil
        }
        save()
    }

    /// Drops ids that no longer exist. Anything holding a selection across a mutation
    /// needs this or it starts commanding ghosts.
    func existing(_ ids: Set<UUID>) -> Set<UUID> {
        let live = Set(items.map(\.id))
        return ids.intersection(live)
    }

    /// Deletes attachment files that no item references any more.
    ///
    /// Without this, deleting a note with a screenshot left its PNG in `attachments/`
    /// forever — the folder only ever grew, and nothing in the app could see it.
    /// Runs after any deletion; it only removes files, never items.
    func sweepOrphanedAttachments() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.attachments,
                                                     includingPropertiesForKeys: nil)
        else { return }

        // Everything still referenced, including by items sitting in the archive file.
        var referenced = Set(items.compactMap(\.imagePath))
        if let archive = try? String(contentsOf: Self.archiveFile, encoding: .utf8) {
            referenced.formUnion(MarkdownFile.parse(archive).items.compactMap(\.imagePath))
        }
        let keep = Set(referenced.map { URL(fileURLWithPath: $0).lastPathComponent })

        for file in files where !keep.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        checkpoint(ids.count == 1 ? "Delete" : "Delete \(ids.count) items")
        items.removeAll { ids.contains($0.id) }
        save()
        // Deliberately NOT sweeping here: undo can bring these items back, and an
        // unlinked PNG cannot be un-deleted. The sweep runs at launch instead, by which
        // point the undo stack is empty.
    }

    /// Move items into a list, creating it if it doesn't exist yet.
    @discardableResult
    func moveCreatingSection(_ ids: Set<UUID>, to name: String) -> Bool {
        let section = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !section.isEmpty, !ids.isEmpty else { return false }
        checkpoint("Move")
        if !sections.contains(section) { sections.append(section) }
        for i in items.indices where ids.contains(items[i].id) {
            items[i].section = section
        }
        save()
        return true
    }

    /// Reorder lists. They were stuck in creation order with no way to change it.
    func moveSection(from offsets: IndexSet, to destination: Int) {
        checkpoint("Reorder lists")
        sections.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func setText(_ text: String, for id: UUID) {
        // Checkpoint AFTER the guard — a no-op mutation used to push a phantom undo
        // entry, so ⌘Z appeared to do nothing and the second press ate a real edit.
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("Edit")
        items[i].text = text
        save()
    }

    /// Reorder within a section. `offsets`/`destination` are indices into that section's slice.
    func move(in section: String, from offsets: IndexSet, to destination: Int) {
        checkpoint("Reorder")
        var slice = items(in: section)
        slice.move(fromOffsets: offsets, toOffset: destination)
        var rest = items.filter { $0.section != section }
        // Rebuild preserving the order of other sections as they appear.
        var rebuilt: [Item] = []
        var inserted = false
        for s in sections {
            if s == section {
                rebuilt.append(contentsOf: slice)
                inserted = true
            } else {
                rebuilt.append(contentsOf: rest.filter { $0.section == s })
            }
        }
        if !inserted { rebuilt.append(contentsOf: slice) }
        rest.removeAll()
        items = rebuilt
        save()
    }

    /// Move items into another section, keeping their relative order.
    func move(ids: Set<UUID>, toSection section: String) {
        guard !ids.isEmpty else { return }
        checkpoint("Move")
        if !sections.contains(section) { sections.append(section) }
        for i in items.indices where ids.contains(items[i].id) {
            items[i].section = section
        }
        save()
    }

    /// Combine several items into one, in the order they appear in the list.
    /// The first one survives and absorbs the rest, so its section and source stay put.
    /// Returns the surviving item's id so the caller can keep it selected.
    @discardableResult
    func merge(_ ids: Set<UUID>) -> UUID? {
        let chosen = items.filter { ids.contains($0.id) }
        guard chosen.count > 1, let first = chosen.first else { return nil }
        checkpoint("Merge \(chosen.count) notes")

        let joined = chosen.map(\.text).joined(separator: "\n\n")
        let survivor = first.id
        items.removeAll { ids.contains($0.id) && $0.id != survivor }
        if let i = items.firstIndex(where: { $0.id == survivor }) {
            items[i].text = joined
            items[i].done = false          // a freshly merged note isn't finished
            items[i].completedAt = nil
        }
        save()
        return survivor
    }

    // MARK: - Archive

    /// Ticked-off items live here once cleared. A second plain markdown file, so the
    /// live queue stays small and the archive stays readable and greppable.
    static var archiveFile: URL { folder.appendingPathComponent("Sill-Archive.md") }

    @Published private(set) var archive: [Item] = []

    func loadArchive() {
        guard let text = try? String(contentsOf: Self.archiveFile, encoding: .utf8) else {
            archive = []
            return
        }
        archive = MarkdownFile.parse(text).items
    }

    /// Append, then rewrite the live file. Order matters: a crash between the two leaves a
    /// duplicate, which is recoverable. The opposite order loses the item.
    private func appendToArchive(_ moved: [Item]) {
        guard !moved.isEmpty else { return }
        loadArchive()

        // Items must be re-homed into the section we serialize under. `serialize` only
        // emits items whose section matches one it was given — passing ["Archive"] while
        // the items still said "Inbox" wrote an EMPTY file and lost every one of them.
        let stamped = moved.map { item -> Item in
            var copy = item
            copy.section = Self.archiveSection
            return copy
        }
        let combined = archive + stamped
        let text = MarkdownFile.serialize(items: combined, sections: [Self.archiveSection])

        // Refuse to write anything that doesn't survive a round trip. This is the exact
        // class of bug that silently emptied the archive, so it gets a hard check.
        guard MarkdownFile.parse(text).items.count == combined.count else {
            lastWriteError = "Archive write aborted — the file would have lost items."
            return
        }

        do {
            try FileManager.default.createDirectory(at: Self.folder,
                                                    withIntermediateDirectories: true)
            try text.write(to: Self.archiveFile, atomically: true, encoding: .utf8)
            archive = combined
        } catch {
            lastWriteError = "Couldn’t write the archive — \(error.localizedDescription)"
        }
    }

    static let archiveSection = "Archive"

    /// Bring an archived item back to the live queue, undone.
    func restore(_ ids: Set<UUID>) {
        let returning = archive.filter { ids.contains($0.id) }
        guard !returning.isEmpty else { return }
        checkpoint(returning.count == 1 ? "Restore" : "Restore \(returning.count)")

        for var item in returning {
            item.done = false
            item.completedAt = nil
            if !sections.contains(item.section) { item.section = sections.first ?? "Inbox" }
            items.append(item)
        }
        archive.removeAll { ids.contains($0.id) }
        let text = MarkdownFile.serialize(items: archive, sections: ["Archive"])
        try? text.write(to: Self.archiveFile, atomically: true, encoding: .utf8)
        save()
    }

    // MARK: - Lists

    /// Delete a list. Its items move to Inbox rather than being destroyed — deleting a
    /// container should never silently delete its contents. Undoable either way.
    @discardableResult
    func deleteSection(_ name: String) -> Int {
        guard sections.contains(name), sections.count > 1 else { return 0 }
        let moved = items.filter { $0.section == name }.count
        checkpoint("Delete list \(name)")

        let fallback = sections.first { $0 != name } ?? "Inbox"
        for i in items.indices where items[i].section == name {
            items[i].section = fallback
        }
        sections.removeAll { $0 == name }
        save()
        return moved
    }

    func renameSection(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sections.contains(old), !name.isEmpty, !sections.contains(name) else { return }
        checkpoint("Rename list")
        for i in items.indices where items[i].section == old {
            items[i].section = name
        }
        if let index = sections.firstIndex(of: old) { sections[index] = name }
        save()
    }

    func count(in section: String) -> Int {
        items.filter { $0.section == section && !$0.done }.count
    }

    /// Cleared items move to the archive rather than being destroyed. The whole drain
    /// model depends on people trusting that ticking something off doesn't lose it.
    @discardableResult
    func clearDone() -> Int {
        let finished = items.filter(\.done)
        guard !finished.isEmpty else { return 0 }
        checkpoint(finished.count == 1 ? "Clear 1 done item" : "Clear \(finished.count) done items")
        appendToArchive(finished)
        items.removeAll(where: \.done)
        save()
        return finished.count
    }

    /// Empty a whole list in one action, archiving whatever was in it.
    @discardableResult
    func emptyList(_ section: String) -> Int {
        let going = items.filter { $0.section == section }
        guard !going.isEmpty else { return 0 }
        checkpoint("Empty \(section)")
        appendToArchive(going.map { var copy = $0; copy.done = true
                                    copy.completedAt = Date(); return copy })
        items.removeAll { $0.section == section }
        save()
        return going.count
    }

    // MARK: - Images

    /// Computed, not `let`: a stored value froze the path at launch, so after the store
    /// was relocated images were written to the old folder and read from the new one —
    /// every new screenshot rendered as "Missing image".
    static var attachments: URL { folder.appendingPathComponent("attachments", isDirectory: true) }

    /// Saves a pasted or captured image beside the markdown and files a normal item that
    /// references it. Stays inside the plain-markdown promise: the item is just
    /// `![](attachments/…png)`, which renders in Obsidian, on GitHub, and anywhere else.
    @discardableResult
    func addImage(_ png: Data, caption: String?, to section: String, source: Source? = nil) -> Bool {
        let stamp = Self.fileStamp.string(from: Date())
        let name = "sill-\(stamp).png"
        do {
            try FileManager.default.createDirectory(at: Self.attachments,
                                                    withIntermediateDirectories: true)
            try png.write(to: Self.attachments.appendingPathComponent(name))
        } catch {
            lastWriteError = "Couldn’t save the image — \(error.localizedDescription)"
            return false
        }

        let alt = caption?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "image"
        add("![\(alt)](attachments/\(name))", kind: .note, to: section, source: source)
        return true
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    // MARK: - Getting text back out

    /// One item: its text, verbatim. Several — or an explicit "as list" — numbered,
    /// because that's what reads correctly when pasted into a chat as a set of questions.
    ///
    /// `asList` used to be accepted and then ignored, which made ⇧⌘C identical to ⌘C.
    func copyText(for ids: Set<UUID>, asList: Bool = false) -> String {
        // Keep the on-screen order, not the arbitrary order of a Set.
        let chosen = items.filter { ids.contains($0.id) }
        if chosen.count == 1 && !asList { return chosen[0].text }

        // Number the first line only. Re-indenting every line would mangle code blocks
        // and nested lists inside an item.
        return chosen.enumerated().map { index, item -> String in
            let lines = item.text.components(separatedBy: "\n")
            return (["\(index + 1). \(lines.first ?? "")"] + lines.dropFirst())
                .joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Mark items done. Takes its own checkpoint: this is called as the side effect of
    /// Copy as List, and without it ⌘Z silently skipped past the tick-off and undid
    /// whatever the user did *before* that — verified by hand.
    func markDone(_ ids: Set<UUID>) {
        guard items.contains(where: { ids.contains($0.id) && !$0.done }) else { return }
        checkpoint(ids.count == 1 ? "Mark done" : "Mark \(ids.count) done")
        for i in items.indices where ids.contains(items[i].id) && !items[i].done {
            items[i].done = true
            items[i].completedAt = Date()
        }
        save()
    }

    // MARK: - Disk

    /// Set when the file exists but could not be read (wrong encoding, a stray non-UTF-8
    /// byte, an iCloud-evicted placeholder). While true, saving is refused — otherwise
    /// the app would sit there with an empty list and the next keystroke would overwrite
    /// a perfectly good file with nothing.
    @Published private(set) var loadError: String?

    /// Lines in the file that Sill didn't write — paragraphs, sub-headings, quotes.
    /// Carried through every save so editing the file by hand isn't punished.
    private var foreign: [Foreign] = []

    func load() {
        let url = Self.resolvedFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = nil    // first run: no file yet is not an error
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = MarkdownFile.parse(text)
            items = parsed.items
            sections = parsed.sections
            foreign = parsed.foreign
            lastWrittenText = text
            loadError = nil
        } catch {
            // Do not touch the file. Report and go read-only.
            loadError = "Couldn’t read Sill.md — saving is paused so nothing is overwritten."
            NSLog("Sill: load failed — \(error.localizedDescription)")
        }
    }

    /// Fingerprint of the file as we last wrote it, so we can tell our own writes from
    /// somebody else's.
    private var lastWrittenText: String?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: CInt = -1

    /// Watches the *folder*, not the file.
    ///
    /// Atomic saves — ours and every editor's, including Obsidian and vim — replace the
    /// file's inode, so a watch on the file itself sees one rename and then monitors
    /// something nobody will ever write to again. Watching the directory survives that.
    func startWatchingFolder() {
        stopWatchingFolder()
        try? FileManager.default.createDirectory(at: Self.folder,
                                                 withIntermediateDirectories: true)
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // Editors write two or three times per save; coalesce.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.reloadIfChangedOnDisk()
            }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        watcher = source
    }

    func stopWatchingFolder() {
        watcher?.cancel()
        watcher = nil
        watchedDescriptor = -1
    }

    /// Reload if the file changed underneath us.
    ///
    /// Without this, editing `Sill.md` in Obsidian while Sill was running meant the next
    /// capture silently overwrote everything you'd typed. Called whenever the panel is
    /// shown and whenever another app hands focus back.
    func reloadIfChangedOnDisk() {
        guard loadError == nil,
              let onDisk = try? String(contentsOf: Self.resolvedFile, encoding: .utf8),
              onDisk != lastWrittenText
        else { return }

        let parsed = MarkdownFile.parse(onDisk)
        // Only take it if it actually parses to something — a half-written file mid-save
        // from another editor shouldn't wipe the panel.
        guard !parsed.items.isEmpty || items.isEmpty else { return }

        items = parsed.items
        sections = parsed.sections
        foreign = parsed.foreign
        lastWrittenText = onDisk
        // Anything the reload removed can't be undone back into existence sensibly.
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func save() {
        guard loadError == nil else { return }

        let text = MarkdownFile.serialize(items: items, sections: sections, foreign: foreign)
        let url = Self.resolvedFile
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            // Write to a sibling then swap, so a crash mid-write can't truncate the real file.
            let tmp = Self.folder.appendingPathComponent(".Sill.md.tmp")
            try text.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            lastWrittenText = text
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
            NSLog("Sill: save failed — \(error.localizedDescription)")
        }
    }

    /// Surfaced by the UI so a failing save is never silent.
    @Published private(set) var lastWriteError: String?

    /// `replaceItemAt` fails outright when the target is a symlink — which is exactly what
    /// a markdown-first user does: `ln -s ~/vault/Sill.md ~/Documents/Sill/Sill.md`.
    /// Resolving first means the swap happens against the real file.
    private static var resolvedFile: URL {
        file.resolvingSymlinksInPath()
    }
}

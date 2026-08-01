import SwiftUI
import AppKit
import ImageIO

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var state: PanelState

    @FocusState private var focus: Field?
    @State private var hoveringChrome = false
    @State private var renameDraft = ""
    private enum Field: Hashable { case search, composer, list, rename }

    /// Invisible element at the end of the list, so "scroll to the bottom" means the
    /// actual bottom rather than the last note's edge.
    private static let bottomAnchor = "sill.bottom"

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            header
            staleGrantBanner
            storeProblem
            content
            composer
        }
        // Key handling lives on the outer stack, not on the ScrollView. A ScrollView
        // can't take keyboard focus, and it only exists when the list is non-empty —
        // so Space/Delete/Esc were dead on first run and unreliable after.
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .list)
        .onKeyPress(.space) {
            guard focus == .list, !state.selection.isEmpty else { return .ignored }
            toggleDone(); return .handled
        }
        .onKeyPress(.delete) {
            guard focus == .list, !state.selection.isEmpty else { return .ignored }
            deleteSelected(); return .handled
        }
        // `onExitCommand` is AppKit's cancelOperation, which Escape actually routes to.
        // `.onKeyPress(.escape)` and a hidden button with `.keyboardShortcut(.escape)`
        // were both tried and neither fires — SwiftUI reserves Escape for cancel roles.
        .onExitCommand { dismissStep() }
        .onAppear { state.dismissStep = { dismissStep() } }
        .onKeyPress(.upArrow)   { moveCursor(-1) }
        .onKeyPress(.downArrow) { moveCursor(+1) }
        // ↩ edits the selected item. The shortcuts sheet has been advertising this;
        // the binding never existed.
        .onKeyPress(.return) {
            guard focus == .list, state.selection.count == 1,
                  let id = state.selection.first else { return .ignored }
            state.editing = id
            return .handled
        }
        // →/← expand and collapse, the way a disclosure works everywhere else on the Mac.
        .onKeyPress(.rightArrow) {
            guard focus == .list, let id = state.selection.first else { return .ignored }
            state.expanded.insert(id)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard focus == .list, let id = state.selection.first else { return .ignored }
            state.expanded.remove(id)
            return .handled
        }
        .onHover { hoveringChrome = $0 }
        // The panel is summoned to write something down, so the composer gets the caret.
        // Without this AppKit hands first responder to the search field.
        .onChange(of: state.focusComposerToken) { focus = .composer }
        // Translucent, so the panel sits *on* the desktop rather than on top of it like a
        // pasted screenshot. No borders and no dividers anywhere — separation is fill and space.
        // `drawingGroup` keeps the blur from being recomposited on every state change.
        .background(
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Theme.bg.opacity(0.55))
            }
            .drawingGroup()
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .background(commands)
        .overlay(alignment: .top) { renameField }
    }

    /// Renaming happens inline at the top of the panel rather than in a dialog — a modal
    /// over a floating panel steals focus from the app you're working in.
    @ViewBuilder
    private var renameField: some View {
        if let original = state.renaming {
            HStack(spacing: 8) {
                Text("Rename list")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                TextField(original, text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .focused($focus, equals: .rename)
                    .onSubmit {
                        let wanted = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !wanted.isEmpty else {
                            state.flash("A list needs a name"); return
                        }
                        guard !store.sections.contains(wanted) || wanted == original else {
                            state.flash("“\(wanted)” already exists"); return
                        }
                        store.renameSection(original, to: wanted)
                        if state.focused == original { state.focused = wanted }
                        if state.activeSection == original { state.activeSection = wanted }
                        state.renaming = nil
                    }
                Button("Cancel") { state.renaming = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Theme.pad)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            )
            .padding(.horizontal, Theme.panelPad)
            .padding(.top, 30)
            .onAppear { renameDraft = original; focus = .rename }
        }
    }

    // MARK: - Chrome

    /// A real place to grab the window. Every card is `.draggable` for reordering, which
    /// claims the drag before the window can — so without this the panel was only movable
    /// in the 12pt gutters between cards.
    private var dragHandle: some View {
        WindowDragHandle()
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .overlay(
                Capsule()
                    .fill(Theme.muted.opacity(hoveringChrome ? 0.38 : 0.16))
                    .frame(width: 36, height: 4)
            )
            .animation(Theme.reduceMotion ? nil : Theme.hover, value: hoveringChrome)
            .accessibilityLabel("Drag to move Sill")
    }

    /// Ticked-off items, still readable and restorable. The drain model only works if
    /// people can see that nothing was destroyed.
    @ViewBuilder
    private var archiveList: some View {
        if store.archive.isEmpty {
            VStack(spacing: 7) {
                Text("Archive is empty")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Ticked-off items land here when you clear them.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                Button("Back to queue") { state.showingArchive = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.cardGap) {
                    sectionHeader("Archive")
                    ForEach(store.archive.reversed()) { item in
                        ItemCard(item: item,
                                 selected: state.selection.contains(item.id),
                                 onToggle: { store.restore([item.id])
                                             state.flash("Restored to your queue") },
                                 onReveal: { reveal(item) })
                            .contentShape(Rectangle())
                            .onTapGesture { state.selection = [item.id] }
                            .contextMenu {
                                Button("Restore to Queue") {
                                    store.restore(ids(including: item))
                                    state.flash("Restored")
                                }
                                Button("Copy") { copy(ids: ids(including: item)) }
                            }
                            .id(item.id)
                    }
                }
                .padding(.horizontal, Theme.panelPad)
                .padding(.top, 4)
                .padding(.bottom, Theme.panelPad)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Move the selection up or down the flattened list.
    private func moveCursor(_ delta: Int) -> KeyPress.Result {
        let flat = visibleSections.flatMap { rows(in: $0) }
        guard !flat.isEmpty else { return .ignored }
        guard let current = state.selection.first,
              let index = flat.firstIndex(where: { $0.id == current }) else {
            state.selection = [delta > 0 ? flat[0].id : flat[flat.count - 1].id]
            focus = .list
            return .handled
        }
        let next = max(0, min(flat.count - 1, index + delta))
        state.selection = [flat[next].id]
        focus = .list
        return .handled
    }

    /// Nothing was warning the user when writes failed. If macOS denies access to
    /// Documents, captures land, toasts say "Captured", and the file is never written —
    /// everything vanishes on quit with no indication it was ever at risk.
    /// The specific, confusing case: System Settings shows Sill switched ON, but macOS
    /// doesn't trust it, because the grant is tied to a fingerprint of the app that changed
    /// on the last update. Re-prompting does nothing. Only toggling it off and on works.
    @ViewBuilder
    private var staleGrantBanner: some View {
        if Capture.grantIsStale {
            VStack(alignment: .leading, spacing: 3) {
                Text("Accessibility needs re-approving")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("The switch still looks on. Turn Sill off, then on again.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { Capture.openAccessibilitySettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.pad)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .padding(.horizontal, Theme.panelPad)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var storeProblem: some View {
        if let problem = store.loadError ?? store.lastWriteError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not saving")
                        .font(.system(size: 12, weight: .semibold))
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show the folder") {
                        NSWorkspace.shared.open(Store.folder)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.top, 2)
                }
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.pad)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .padding(.horizontal, Theme.panelPad)
            .padding(.top, 8)
        }
    }

    /// Lives in the panel, next to search — the same place the reference puts it.
    /// A menu-bar item is the wrong home for things you reach for while looking at the list.
    private var overflowMenu: some View {
        Menu {
            // Lists sit at the top level, not in a submenu — one click to switch, which
            // is how the reference does it and it's plainly better.
            Button("All Lists") { state.focused = nil }
            ForEach(store.sections, id: \.self) { name in
                Button {
                    state.focused = name
                    state.activeSection = name
                } label: {
                    // Count included: with several lists you otherwise have to switch to
                    // each one to find out whether anything is waiting in it.
                    Text("\(state.focused == name ? "✓  " : "     ")\(name)"
                         + (store.count(in: name) > 0 ? "  (\(store.count(in: name)))" : ""))
                }
            }
            Button("New List…") {
                if state.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.composer = "# "
                }
                focus = .composer
            }

            // Managing lists, not just switching between them. There was no way to
            // remove or rename one at all — you could create them and never clean up.
            // Only when there is something to manage. `.disabled` was wrong here:
            // SwiftUI greys out a disabled Button but NOT a disabled Menu, so with
            // Inbox as your only list this rendered in full black and did nothing
            // when clicked — a button that looks live and isn't.
            let managed = store.sections.filter { $0 != "Inbox" }
            if !managed.isEmpty {
                Menu("Manage Lists") {
                    ForEach(managed, id: \.self) { name in
                    Menu(name) {
                        Button("Rename…") { state.renaming = name }
                        Button("Delete List", role: .destructive) {
                            let moved = store.deleteSection(name)
                            if state.focused == name { state.focused = nil }
                            // Without this the next capture recreates the list you just
                            // deleted, because `add` re-creates any missing section.
                            if state.activeSection == name {
                                state.activeSection = store.sections.first ?? "Inbox"
                            }
                            state.flash(moved == 0
                                        ? "Deleted “\(name)” — ⌘Z to undo"
                                        : "Deleted “\(name)”, \(moved) moved to Inbox — ⌘Z")
                        }
                    }
                    }
                }
            }

            Divider()

            Button(doneCount > 0 ? "Clear Done (\(doneCount))" : "Clear Done") {
                let n = store.clearDone()
                state.flash(n == 0 ? "Nothing ticked off yet"
                                   : "Archived \(n) — see Archive below")
            }
            .disabled(doneCount == 0)

            Button(state.showingArchive ? "Back to Queue" : "Archive (\(store.archive.count))") {
                state.showingArchive.toggle()
                if state.showingArchive { store.loadArchive() }
                state.selection = []
            }

            if let list = state.focused {
                Button("Empty “\(list)”") {
                    let n = store.emptyList(list)
                    state.flash(n == 0 ? "Already empty" : "Archived \(n) from \(list) — ⌘Z")
                }
            }

            Button("Keyboard Shortcuts") { state.showShortcuts() }
            Button("Open Notes Folder") { NSWorkspace.shared.open(Store.folder) }
            Button("Choose Notes Folder…") { chooseFolder() }

            Divider()
            Section("Window") {
                Toggle("Keep on Top", isOn: $state.keepOnTop)
                Button("Close") { state.requestHide() }
            }

            Menu("Appearance") {
                ForEach(PanelState.Appearance.allCases, id: \.self) { mode in
                    Button {
                        state.appearance = mode
                    } label: {
                        Label(mode.label,
                              systemImage: state.appearance == mode ? "checkmark" : "")
                    }
                }
            }

            Divider()

            Button("Undo \(store.lastUndoLabel ?? "")") {
                if let label = store.undo() { state.flash("Undid \(label.lowercased())") }
            }
            .disabled(!store.canUndo)

        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var doneCount: Int { store.items.filter(\.done).count }

    /// Point the store somewhere else — an Obsidian vault, a git repo, a synced folder.
    /// The whole reason the format is plain markdown.
    private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = "Use This Folder"
        picker.message = "Where should Sill keep your notes?"
        picker.directoryURL = Store.folder

        guard picker.runModal() == .OK, let chosen = picker.url else { return }
        if let problem = store.relocate(to: chosen) {
            state.flash("Couldn’t move: \(problem)")
        } else {
            state.flash("Notes now live in \(chosen.lastPathComponent)")
        }
    }

    /// Deleting several at once asks first. Undo exists, but a silent bulk destroy is
    /// the kind of thing you only notice after quitting.
    private func confirmDelete(_ ids: Set<UUID>) {
        guard ids.count > 1 else { delete(ids: ids); return }

        let alert = NSAlert()
        alert.messageText = "Delete \(ids.count) items?"
        alert.informativeText = "They won't go to the archive. ⌘Z can bring them back "
                              + "until you quit."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { delete(ids: ids) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)

            TextField("Search", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .focused($focus, equals: .search)

            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            overflowMenu

            if let focused = state.focused {
                Text(focused.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.surface))
                    .accessibilityLabel("Showing only \(focused). Press Command K to change.")
            }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 9)
        // Opaque: a translucent search field let scrolled text show through it.
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surface)
        )
        .padding(.horizontal, Theme.panelPad)
        .padding(.bottom, 4)
    }

    // MARK: - List

    private var visibleSections: [String] {
        if let focused = state.focused { return [focused] }
        return store.sections
    }

    /// Grouped once per body pass instead of per section per call. `rows(in:)` used to be
    /// invoked several times for every section on every redraw — each one filtering the
    /// whole item array — which made clicking a card visibly slow.
    private var grouped: [String: [Item]] {
        var out: [String: [Item]] = [:]
        let query = state.query
        let lingering = state.lingering
        for item in store.items {
            // Ticked-off items leave the panel after a beat. They are still in the file —
            // the panel is the live queue, not the archive.
            guard !item.done || lingering.contains(item.id) else { continue }
            if !query.isEmpty, !item.text.localizedCaseInsensitiveContains(query) { continue }
            out[item.section, default: []].append(item)
        }
        return out
    }

    private func rows(in section: String) -> [Item] {
        grouped[section] ?? []
    }

    private var isEmpty: Bool {
        let groups = grouped
        return visibleSections.allSatisfy { (groups[$0] ?? []).isEmpty }
    }

    /// Deliberately not a `List`. `List` brings macOS's stock blue selection bar, its own
    /// row insets and separators, and a look that belongs to the system rather than this app.
    @ViewBuilder
    private var content: some View {
        // Grouped once here, then read from the dictionary — not recomputed per section.
        let groups = grouped
        if state.showingArchive {
            archiveList
        } else if visibleSections.allSatisfy({ (groups[$0] ?? []).isEmpty }) {
            emptyState
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.cardGap) {
                    ForEach(visibleSections, id: \.self) { section in
                        let all = groups[section] ?? []
                        let live = all.filter { !$0.isOlder() }
                        let older = all.filter { $0.isOlder() }

                        if !all.isEmpty {
                            if visibleSections.count > 1 || store.sections.count > 1 {
                                sectionHeader(section)
                            }
                            ForEach(live) { item in row(item, in: section) }

                            // Week-old captures sink here. They are never deleted and
                            // never nag — they just stop competing with live work.
                            if !older.isEmpty {
                                sectionHeader("Older")
                                ForEach(older) { item in row(item, in: section) }
                            }
                        }
                    }
                    // Scrolling to the last *note* aligns that note with the viewport
                    // edge — which is inside the fade. Scrolling to a spacer past it lands
                    // where a manual scroll-to-end lands, with the note fully clear.
                    Color.clear
                        .frame(height: 34)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, Theme.panelPad)
                .padding(.top, 4)
                // Drives the leave transition and the rows closing the gap behind it.
                .animation(Theme.reduceMotion ? nil : Theme.leave, value: state.lingering)
            }
            // Hidden, not visible: the fade mask below applies to the scrollbar too, which
            // made it smear into an odd tapering blob while scrolling.
            .scrollIndicators(.hidden)
            // Content used to be cut off mid-glyph at the top edge. Fading it out over the
            // first 18pt makes a partly-scrolled line read as "there's more above" instead
            // of as a rendering fault.
            .mask(
                // Fade at both ends. The trailing padding below is sized to clear this
                // band, so at the end of the list the last note sits fully above the fade
                // and stays crisp — the fade lands on empty space, not on the note.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.035),
                        .init(color: .black, location: 0.965),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            // A capture appends to the bottom of its section. Past about a dozen items
            // that's off-screen, so the only evidence it worked was a toast that vanished
            // in 1.6 seconds — which reads as "nothing happened".
            .onChange(of: store.items.count) {
                // `store.items.last` is the last item in file order, which is not the last
                // row on screen once there are several lists. Scroll to the row that
                // actually renders last, and do it after layout has settled — scrolling in
                // the same turn as the insert lands short, which is the "doesn't quite go
                // to the bottom" symptom.
                guard let lastVisible = visibleSections.reversed()
                        .compactMap({ (groups[$0] ?? []).last?.id }).first
                else { return }
                _ = lastVisible
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    withAnimation(Theme.reduceMotion ? nil : Theme.spring) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.selection) {
                guard let id = state.selection.first else { return }
                withAnimation(Theme.reduceMotion ? nil : Theme.quick) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            }
        }
    }

    private func row(_ item: Item, in section: String) -> some View {
        ItemCard(item: item,
                 selected: state.selection.contains(item.id),
                 onToggle: { toggle(item) },
                 onReveal: { reveal(item) },
                 onCommit: { store.setText($0, for: item.id) },
                 editRequested: state.editing == item.id,
                 isExpanded: state.expanded.contains(item.id),
                 onEditStarted: { state.editing = nil })
            .contentShape(Rectangle())
            // SwiftUI's own modifier-aware gestures, rather than reading the global
            // NSEvent.modifierFlags inside a plain tap — that races the event and was
            // making ⌘-click behave like an ordinary click about half the time.
            // ONE recognizer. Three stacked gestures all fired on every click, so a single
            // click re-rendered the whole list four times — measured, and the cause of the
            // visible lag. Modifiers are read from the event at the moment of the tap.
            .onTapGesture {
                let mods = NSEvent.modifierFlags
                if mods.contains(.command) { toggleInSelection(item) }
                else if mods.contains(.shift) { extendSelection(to: item) }
                else if state.selection != [item.id] { state.selection = [item.id] }
                // Focus follows the click. Without this the panel never becomes the key
                // responder, so Esc, Space and the arrows were silently dropped after
                // selecting a note with the mouse.
                focus = .list
            }
            .contextMenu { menu(for: item) }
            .draggable(item.id.uuidString)
            .dropDestination(for: String.self) { payload, _ in
                drop(payload, before: item, in: section)
            }
            .id(item.id)
            // Leaving the panel: fade out while sliding 10pt right, and the rows below
            // close the gap. Exactly the mockup's motion.
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity.combined(with: .offset(x: 10))
            ))
    }

    /// Label plus a rule running to the right inset. That single line is what makes a
    /// section header read as structure rather than a small grey word.
    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(Theme.muted)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
        .padding(.top, Theme.sectionGap - Theme.cardGap)
        .padding(.bottom, 2)
    }

    /// Four genuinely different situations, not two.
    ///
    /// "No matches" is keyed on there being a *search*, not on the store having items.
    /// It used to key on `store.items` — so once everything was ticked off and drained,
    /// a panel with nothing in it announced "Nothing here matches """ with an empty query.
    private enum Emptiness { case fresh, allClear, noMatches, emptyList }

    private var emptiness: Emptiness {
        if !state.query.isEmpty { return .noMatches }
        if store.items.isEmpty { return .fresh }
        if state.focused != nil { return .emptyList }
        return .allClear          // items exist, but they're all ticked off
    }

    /// An empty panel is the one moment the user is looking at nothing, so it's the one
    /// place a few shortcuts can be taught without being in the way.
    private var shortcutGuide: some View {
        VStack(spacing: 7) {
            shortcutRow(Capture.isTrusted ? "Capture selected text" : "Capture what you copied",
                        "⇧  ⇧")
            shortcutRow("Tick off and copy", "⇧ ⌘ C")
            shortcutRow("Start a list", "# Name  ↩")
            shortcutRow("See all shortcuts", "⌘ /")
        }
        .frame(maxWidth: 260)
    }

    private func shortcutRow(_ label: String, _ keys: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(keys)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.ink.opacity(0.06))
                )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            switch emptiness {
            case .fresh:
                Text("Nothing captured yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("An answer, a link, a screenshot, a half-formed prompt. It all waits here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                shortcutGuide
                    .padding(.top, 14)

            case .allClear:
                Text("All clear")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Everything you ticked off is still in your notes file.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                shortcutGuide
                    .padding(.top, 14)

            case .emptyList:
                Text("Nothing in \(state.focused ?? "this list")")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Button("Show all lists") { state.focused = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)

            case .noMatches:
                Text("No matches")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Nothing here matches “\(state.query)”.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                Button("Clear search") { state.query = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .strokeBorder(Theme.muted.opacity(0.35), lineWidth: 1.25)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)

                TextField("Add a note or describe a task that you want",
                          text: $state.composer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...5)
                    .frame(minHeight: 34, alignment: .top)
                    .focused($focus, equals: .composer)
                    .onSubmit(submit)
                    // Same trap as the item editor: this field is vertical-axis, so
                    // Return means "new line" and .onSubmit alone can't be relied on.
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.isDisjoint(with: [.shift, .option]) else {
                            return .ignored              // ⇧↩ / ⌥↩ make a new line
                        }
                        submit()
                        return .handled
                    }
            }
            .padding(Theme.pad)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .inset(by: -1)
                    // A heavy ink outline read as clunky against an otherwise soft
                    // palette — visible in the first light-mode screenshot.
                    .strokeBorder(Theme.ink.opacity(0.16),
                                  lineWidth: focus == .composer ? 1 : 0)
            )

            // Reserved height, so a toast never re-lays-out the list above it.
            Text(state.toast ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .frame(height: 16, alignment: .leading)
                .opacity(state.toast == nil ? 0 : 1)
                .padding(.top, 5)
        }
        .padding(.horizontal, Theme.panelPad)
        .padding(.bottom, Theme.panelPad - 4)
        .padding(.top, 20)
        .animation(Theme.reduceMotion ? nil : Theme.quick, value: state.toast)
    }

    private func submit() {
        let text = state.composer
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Typed here means you intend to run it, so it's a prompt. Captured text is a note.
        // Only the composer interprets `# ` as a section — never captured text.
        let landed = store.add(text, kind: .prompt, to: state.activeSection,
                               allowSectionSyntax: true)
        if landed != state.activeSection {
            state.activeSection = landed
            state.flash("Section “\(landed)” created")
        }
        state.composer = ""
    }

    // MARK: - Context menu

    @ViewBuilder
    private func menu(for item: Item) -> some View {
        Button("Copy") { copy(ids: ids(including: item)) }
        Button("Copy as List") { copy(ids: ids(including: item), forceList: true) }
        Divider()
        Button(item.done ? "Mark as Not Done" : "Mark as Done") { toggle(item) }

        // Only offered when there's actually more to see — a permanently greyed-out
        // "Expand" teaches people the feature doesn't work.
        if item.text.count > 90 || item.text.contains("\n") {
            Button(state.expanded.contains(item.id) ? "Collapse" : "Expand") {
                if state.expanded.contains(item.id) { state.expanded.remove(item.id) }
                else { state.expanded.insert(item.id) }
            }
        }
        Button("Edit") { state.editing = item.id }
        Divider()
        Button("Merge Notes") {
            let count = state.selection.count
            withAnimation(Theme.reduceMotion ? nil : Theme.spring) {
                if let survivor = store.merge(state.selection) {
                    // Keep the surviving note selected; leaving deleted ids in the
                    // selection is what made every command afterwards misbehave.
                    state.selection = [survivor]
                    state.flash("Merged \(count) — ⌘Z to undo")
                } else {
                    state.flash("Select two or more first")
                }
            }
        }
        .disabled(state.selection.count < 2)
        Button("Send to App") { send(ids: ids(including: item)) }
        if let source = item.source {
            Button("Back to \(source.appName)") { reveal(item) }
        }
        Divider()
        // Shown only when there is somewhere else to move to. A disabled Menu is not
        // greyed out by SwiftUI, so `.disabled` here left a live-looking dead item.
        let elsewhere = store.sections.filter { $0 != item.section }
        if !elsewhere.isEmpty {
            Menu("Move to") {
                ForEach(elsewhere, id: \.self) { section in
                    Button(section) { store.move(ids: ids(including: item), toSection: section) }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { confirmDelete(ids(including: item)) }
    }

    /// Right-clicking inside a multi-selection acts on the whole selection;
    /// right-clicking outside it acts on just that item, as macOS does everywhere.
    private func ids(including item: Item) -> Set<UUID> {
        // Filter to live ids: a selection left over from a merge or delete would
        // otherwise carry ghosts into whatever you do next.
        let live = store.existing(state.selection)
        return live.contains(item.id) ? live : [item.id]
    }

    // MARK: - Selection


    /// Escape backs up one level at a time, then closes.
    private func dismissStep() {
        if !state.selection.isEmpty { state.selection = [] }
        else if !state.query.isEmpty { state.query = "" }
        else { state.requestHide() }
    }

    private func toggleInSelection(_ item: Item) {
        if state.selection.contains(item.id) {
            state.selection.remove(item.id)
        } else {
            state.selection.insert(item.id)
        }
    }

    /// ⇧-click selects everything between the last selection and this item.
    private func extendSelection(to item: Item) {
        let flat = visibleSections.flatMap { rows(in: $0) }
        guard let target = flat.firstIndex(where: { $0.id == item.id }) else { return }
        guard let anchor = flat.firstIndex(where: { state.selection.contains($0.id) }) else {
            state.selection = [item.id]
            return
        }
        let range = anchor <= target ? anchor...target : target...anchor
        state.selection = Set(flat[range].map(\.id))
    }

    /// Clicking the checkbox of an item that's part of a selection toggles the whole
    /// selection — otherwise selecting three and clicking one ticks off only that one.
    private func toggle(_ item: Item) {
        let targets = ids(including: item)
        state.linger(targets)                 // hold them on screen so the tick is seen
        withAnimation(Theme.reduceMotion ? nil : Theme.toggle) {
            store.toggleDone(targets)
        }
        state.selection.subtract(targets)
    }

    /// Go back to wherever this came from. A link in the text itself wins — if you pasted
    /// an X URL, clicking should open that post, not just raise the app you copied it in.
    private func reveal(_ item: Item) {
        if let url = item.linkInText {
            NSWorkspace.shared.open(url)
            state.flash("Opening \(url.host() ?? "link")")
            return
        }
        guard let source = item.source else {
            state.flash("No link on this one")
            return
        }
        if !Capture.reveal(source) {
            state.flash("\(source.appName) isn’t running")
        }
    }

    private func drop(_ payload: [String], before target: Item, in section: String) -> Bool {
        guard let dragged = payload.first.flatMap({ UUID(uuidString: $0) }),
              dragged != target.id else { return false }
        let items = store.items(in: section)
        guard let from = items.firstIndex(where: { $0.id == dragged }),
              let to = items.firstIndex(where: { $0.id == target.id }) else { return false }
        withAnimation(Theme.reduceMotion ? nil : Theme.spring) {
            store.move(in: section, from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
        return true
    }

    // MARK: - Commands

    private var commands: some View {
        VStack(spacing: 0) {
            Button("Copy") { copy(ids: state.selection) }
                .keyboardShortcut("c", modifiers: .command)
            Button("Copy as List") { copy(ids: state.selection, forceList: true) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Send to App") { send(ids: state.selection) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Focus Section") { state.cycleFocus(sections: store.sections) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Search") { focus = .search }
                .keyboardShortcut("f", modifiers: .command)
            Button("Shortcuts") { state.showShortcuts() }
                .keyboardShortcut("/", modifiers: .command)
            Button("Undo") { undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { if let label = store.redo() { state.flash("Redo \(label.lowercased())") } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Hide") { state.requestHide() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Hide") { state.requestHide() }
                .keyboardShortcut(".", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func undo() {
        // ⌘Z belongs to the text field while you're typing in it.
        if focus == .composer || focus == .search { return }
        if let label = store.undo() {
            state.selection = []
            state.flash("Undo \(label.lowercased())")
        } else {
            state.flash("Nothing to undo")
        }
    }

    private func toggleDone() {
        guard !state.selection.isEmpty else { state.flash("Select an item first"); return }
        let targets = store.existing(state.selection)
        state.linger(targets)
        withAnimation(Theme.reduceMotion ? nil : Theme.toggle) {
            store.toggleDone(targets)
        }
        state.selection = []
    }

    private func deleteSelected() { confirmDelete(store.existing(state.selection)) }

    private func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { state.flash("Select an item first"); return }
        let count = ids.count
        withAnimation(Theme.reduceMotion ? nil : Theme.spring) {
            store.delete(ids)
        }
        state.selection.subtract(ids)
        state.flash(count == 1 ? "Deleted" : "Deleted \(count) items")
    }

    private func copy(ids: Set<UUID>, forceList: Bool = false) {
        guard !ids.isEmpty else { state.flash("Select an item first"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.copyText(for: ids, asList: forceList),
                                       forType: .string)
        // Ours, not the user's. Without this the next capture sees a "changed" clipboard,
        // decides it's fresh, and re-files the note you just copied out of Sill.
        Capture.markClipboardSeen()

        // Copy as List ticks them off in the same motion. Sending prompts to the chat and
        // marking them done are one act — splitting them is what turns a queue into a pile.
        // Plain ⌘C leaves them alone, because that really is just copying.
        if forceList {
            state.linger(ids)
            withAnimation(Theme.reduceMotion ? nil : Theme.toggle) {
                store.markDone(ids)
            }
            state.selection = []
            state.flash(ids.count == 1 ? "Copied — ticked off"
                                       : "Copied \(ids.count) — ticked off")
        } else {
            state.flash(ids.count == 1 ? "Copied" : "Copied \(ids.count) items")
        }
    }

    private func send(ids: Set<UUID>) {
        guard !ids.isEmpty else { state.flash("Select an item first"); return }
        let text = store.copyText(for: ids)
        // Prefer the app the item came from; fall back to whatever we were last in front of.
        let target = ids.count == 1
            ? (store.items.first { ids.contains($0.id) }?.source ?? state.targetApp)
            : state.targetApp
        if Capture.send(text, to: target) {
            state.flash("Sent to \(target?.appName ?? "app")")
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Capture.markClipboardSeen()
            state.flash("Copied — ⌘V to paste")
        }
    }
}

// MARK: - Attachments

/// A captured screenshot, shown in the card. The item's text is ordinary markdown
/// (`![](attachments/…png)`), so the file stays readable everywhere else.
private struct AttachmentThumbnail: View {
    let path: String
    @State private var image: NSImage?

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    /// Decoded once per path, at panel width rather than full screenshot resolution.
    static func thumbnail(for url: URL) -> NSImage? {
        if let hit = cache[url.path] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 700
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[url.path] = image
        return image
    }

    private var url: URL {
        Store.folder.appendingPathComponent(path)
    }

    var body: some View {
        Group {
            if let image {
                // A definite height, not a max. `.aspectRatio(.fit)` with `maxHeight`
                // reports one size to the layout and draws another, so the scroll view
                // under-measured its own content and stopped short of the real end —
                // the last rows were literally unreachable.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 150)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.ink.opacity(0.08), lineWidth: 1)
                    )
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text("Missing image")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Cached and downscaled. Decoding a full-size screenshot from disk on the main
        // thread every time the row reappeared was stalling clicks by a visible beat.
        .onAppear { image = Self.thumbnail(for: url) }
        .help("Click to open — \(path)")
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Window drag

/// A strip that moves the window. `acceptsFirstMouse` matters: without it, dragging a
/// panel that isn't key costs a click, which is the bug we just fixed elsewhere.
private struct WindowDragHandle: NSViewRepresentable {
    final class Strip: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
    func makeNSView(context: Context) -> NSView { Strip() }
    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Card

private struct ItemCard: View {
    let item: Item
    let selected: Bool
    let onToggle: () -> Void
    let onReveal: () -> Void
    var onCommit: (String) -> Void = { _ in }
    /// Driven from the context menu, which lives up in PanelView.
    var editRequested: Bool = false
    var isExpanded: Bool = false
    var onEditStarted: () -> Void = {}

    @State private var hovering = false
    @State private var hoveringSource = false
    /// Non-nil while editing. Holds the working copy so Esc can restore the original.
    @State private var draft: String?
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            checkbox
            VStack(alignment: .leading, spacing: 4) {
                if let text = draft {
                    TextField("", text: Binding(
                        get: { text },
                        set: { draft = $0 }
                    ), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1...14)
                        .focused($editing)
                        .onSubmit(commit)
                        // A vertical-axis TextField treats Return as "new line", so
                        // .onSubmit never fires and the edit could never be committed.
                        // Verified by hand: Return left the caret in the field.
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.isDisjoint(with: [.shift, .option]) else {
                                return .ignored          // ⇧↩ / ⌥↩ still make a new line
                            }
                            commit()
                            return .handled
                        }
                        .onExitCommand { draft = nil }        // Esc reverts
                        .onChange(of: editing) { if !editing { commit() } }
                } else if let path = item.imagePath {
                    AttachmentThumbnail(path: path)
                        .opacity(item.done ? 0.5 : 1)
                } else {
                Text(item.text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(item.done ? Theme.muted : Theme.ink)
                    // Long captures clamp to 4 lines until you expand them, so one
                    // pasted essay can't push everything else off the panel.
                    .lineLimit(isExpanded ? nil : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The built-in strike, which follows the glyphs and handles multi-line.
                    // A hand-drawn rule was tried and reverted: it measured the frame, not
                    // the text, so it ran the full card width and only drew one line.
                    .strikethrough(item.done, color: Theme.muted)
                    // Double-click to edit. Committing on focus loss rather than
                    // reverting: this panel disappears often and not always on purpose,
                    // and losing typed text to a stray click would be unforgivable.
                    .onTapGesture(count: 2) {
                        draft = item.text
                        editing = true
                    }
                }

                if item.linkInText != nil || item.source != nil {
                    Button(action: onReveal) {
                        HStack(spacing: 3) {
                            Text(linkLabel)
                            // Filled arrow when we have the exact page; hollow when all we
                            // can do is bring the app forward. The icon tells you which.
                            Image(systemName: isExactLink
                                  ? "arrow.up.right.circle.fill"
                                  : "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(hoveringSource ? Theme.ink : Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringSource = $0 }
                    .help(isExactLink ? "Open \(linkLabel)" : "Back to \(linkLabel)")
                }
            }

            // Right-hand label: what it is, or how old it is once it stops being new.
            Text(metaLabel)
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted.opacity(0.9))
                .padding(.top, 2)
                .fixedSize()
        }
        .padding(Theme.pad)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        // Monochrome ring, drawn outside the card so nothing reflows. A tinted fill read
        // as a dirty brown against the warm neutrals; ink reads as deliberate.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .inset(by: -1.5)
                .strokeBorder(Theme.ink.opacity(0.55), lineWidth: selected ? 1.5 : 0)
        )
        // A checked-off card recedes into the panel: it has left the queue. The whole
        // card changes, not just the circle — that's what makes it feel like completion.
        .opacity(item.done ? 0.55 : 1)
        .scaleEffect(item.done ? 0.985 : 1, anchor: .leading)
        .onHover { hovering = $0 }
        .onChange(of: editRequested) {
            guard editRequested, draft == nil else { return }
            draft = item.text
            editing = true
            onEditStarted()
        }
        .animation(Theme.reduceMotion ? nil : Theme.hover, value: hovering)
        .animation(Theme.reduceMotion ? nil : Theme.toggle, value: item.done)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.text)
        .accessibilityValue(item.done ? "Done" : "Not done")
    }

    private func commit() {
        guard let text = draft else { return }
        draft = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != item.text, !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }

    /// A pasted link shows its host ("x.com"); otherwise the app it came from.
    private var linkLabel: String {
        if let host = item.linkInText?.host() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return item.source?.appName ?? ""
    }

    /// True when clicking lands on the exact thing, not merely the right app.
    private var isExactLink: Bool {
        item.linkInText != nil || item.source?.isExact == true
    }

    /// "done" · "6d" · "prompt" / "note". Age wins once an item is more than an hour old,
    /// because by then *when* it landed is more useful than *what kind* it is.
    private var metaLabel: String {
        if item.done { return "done" }
        if let age = item.age(), age.hasSuffix("h") || age.hasSuffix("d") { return age }
        return item.kind == .prompt ? "prompt" : "note"
    }

    private var checkbox: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .strokeBorder(Theme.muted.opacity(item.done ? 0 : 0.40), lineWidth: 1.25)
                if item.done {
                    Circle().fill(Theme.ink.opacity(0.9))
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.surface)
                }
            }
            .frame(width: 16, height: 16)
            // 28pt hit target around a 16pt circle — it looks pressable, so it must be.
            .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .animation(Theme.reduceMotion ? nil : Theme.toggle, value: item.done)
        .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")
    }
}

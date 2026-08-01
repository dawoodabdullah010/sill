import SwiftUI

/// UI state that isn't persisted: what's selected, what's typed, which section is focused.
@MainActor
final class PanelState: ObservableObject {
    @Published var query: String = ""
    @Published var selection: Set<UUID> = []
    @Published var composer: String = ""
    @Published var activeSection: String = "Inbox"

    /// nil = show every section. Non-nil = focus mode, one section at a time (⌘K).
    @Published var focused: String?

    /// Brief confirmation line under the composer. Cleared on a timer.
    @Published var toast: String?

    /// Set by the panel controller so the view can dismiss itself from a keystroke.
    var requestHide: () -> Void = {}

    /// Set by the view so the panel's cancelOperation can drive the same Escape logic.
    var dismissStep: (() -> Void)?

    /// Bumped whenever the composer should take the caret.
    @Published var focusComposerToken = 0

    /// Items ticked off in the last moment. They stay on screen briefly so you see the
    /// tick land, then leave the panel — the list drains instead of growing. Nothing is
    /// deleted; every one of them is still in the markdown file.
    @Published var lingering: Set<UUID> = []

    /// 420ms, matching the interactive mockup: the strikethrough sweeps across (140ms),
    /// you get a beat to register it, then the row leaves.
    func linger(_ ids: Set<UUID>) {
        lingering.formUnion(ids)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            await MainActor.run { self?.lingering.subtract(ids) }
        }
    }

    /// Which item is being edited, and which are shown in full.
    /// Expansion is a reading gesture, so it resets when the panel hides.
    /// Showing the archive instead of the live queue.
    @Published var showingArchive = false

    /// A list being renamed inline from the menu.
    @Published var renaming: String?

    @Published var editing: UUID?
    @Published var expanded: Set<UUID> = []

    /// Follow the system, or override it per-app. Some people want the panel light
    /// while the rest of the Mac is dark.
    enum Appearance: String, CaseIterable {
        case system, light, dark
        var label: String {
            switch self {
            case .system: return "Match System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }
    }

    @Published var appearance: Appearance = .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "SillAppearance")
            onAppearanceChanged(appearance)
        }
    }
    var onAppearanceChanged: (Appearance) -> Void = { _ in }

    /// Panel-level actions the view can trigger, wired up by the controller.
    @Published var keepOnTop = false { didSet { onKeepOnTopChanged(keepOnTop) } }
    var onKeepOnTopChanged: (Bool) -> Void = { _ in }
    var showShortcuts: () -> Void = {}

    /// The app that was in front when the panel was last shown. Needed because the panel
    /// takes key focus to receive ⌘↩ — so by the time "Send to App" runs, synthesised
    /// keystrokes would land in Sill's own composer unless we re-activate this first.
    @Published var targetApp: Source?

    private var toastToken = 0

    /// Token rather than message comparison: two identical messages in a row would
    /// otherwise have the first timer clear the second toast almost immediately.
    func flash(_ message: String) {
        toastToken &+= 1
        let token = toastToken
        toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run {
                guard let self, self.toastToken == token else { return }
                self.toast = nil
            }
        }
    }

    /// ⌘K walks: all sections → first → second → … → all sections.
    func cycleFocus(sections: [String]) {
        guard !sections.isEmpty else { return }
        switch focused {
        case nil:
            focused = sections.first
        case let current?:
            if let i = sections.firstIndex(of: current), i + 1 < sections.count {
                focused = sections[i + 1]
            } else {
                focused = nil
            }
        }
        // Must reset when the cycle wraps back to "show everything". Leaving the old name
        // here meant every later capture silently filed into a section you weren't looking at.
        activeSection = focused ?? sections.first ?? "Inbox"
    }
}

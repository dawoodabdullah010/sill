import AppKit
import SwiftUI

/// A panel that can take keystrokes without activating the app.
///
/// This is the whole reason Sill is native. `.nonactivatingPanel` lets you type
/// into Sill while ChatGPT stays the frontmost app — your cursor never leaves
/// the conversation. No web-technology wrapper can do this on macOS.
final class SillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Clicking must also make the panel key.
    ///
    /// `acceptsFirstMouse` on the hosting view lets a click reach a control without the
    /// window becoming key — which is what we want for the *first* click, but it meant the
    /// panel never took keyboard focus at all. Escape, Space, ⌘Z and the arrows were all
    /// silently dropped from the moment you clicked a note until the panel was reopened.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    var onCancel: (() -> Void)?
}

/// Makes the *first* click count.
///
/// By default AppKit spends the first click on a non-key window making it key, and the
/// control underneath never sees it — so every button needs pressing twice. That is the
/// entire "everything feels laggy" symptom: it isn't slow, it's swallowing your first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController: NSObject {
    private var panel: SillPanel!
    private var escapeMonitor: Any?
    private let store: Store
    private let state: PanelState

    init(store: Store, state: PanelState) {
        self.store = store
        self.state = state
        super.init()
        build()
        state.requestHide = { [weak self] in self?.hide() }
        panel.onCancel = { [weak self] in self?.state.dismissStep?() }

        // Escape never reaches the window. Verified by logging every event in
        // `SillPanel.sendEvent`: Space arrives (keyCode 49, isKey=true) and Escape
        // (keyCode 53) does not appear at all — so no view-level handler could ever
        // have caught it. A local monitor sees the event before window dispatch.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.panel.isKeyWindow == true else { return event }
            self?.state.dismissStep?()
            return nil                       // swallow it
        }
        state.keepOnTop = UserDefaults.standard.bool(forKey: Self.keepOnTopKey)
        state.onKeepOnTopChanged = { [weak self] on in self?.keepOnTop = on }

        state.onAppearanceChanged = { [weak self] mode in self?.apply(mode) }
        if let saved = UserDefaults.standard.string(forKey: "SillAppearance"),
           let mode = PanelState.Appearance(rawValue: saved) {
            state.appearance = mode
        }
        apply(state.appearance)
    }

    private func build() {
        let root = PanelView(store: store, state: state)
            .environmentObject(store)
            .environmentObject(state)

        panel = SillPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 600),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = UserDefaults.standard.bool(forKey: Self.keepOnTopKey)
            ? .screenSaver : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = FirstMouseHostingView(rootView: root)
        panel.acceptsMouseMovedEvents = true

        // Without bounds the panel can be dragged down to an unusable stub, and a frame
        // restored from a bigger display can end up taller than the current screen.
        panel.minSize = NSSize(width: 320, height: 240)
        panel.maxSize = NSSize(width: 560, height: 20_000)

        // Restore the user's position if they've moved it; otherwise dock to the edge.
        // `setFrameUsingName` reports whether a saved frame actually existed, which is
        // the only reliable way to tell a first launch from a later one.
        panel.setFrameAutosaveName(Self.autosaveName)
        if !panel.setFrameUsingName(Self.autosaveName) {
            dockToRightEdge()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rehomeIfOffscreen),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private static let autosaveName = "SillPanel"

    var isVisible: Bool { panel.isVisible }

    /// nil appearance means "inherit from the system", which is the default.
    private func apply(_ mode: PanelState.Appearance) {
        switch mode {
        case .system: panel.appearance = nil
        case .light:  panel.appearance = NSAppearance(named: .aqua)
        case .dark:   panel.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// `.floating` sits above ordinary windows but below full-screen apps and other
    /// floating panels. `.screenSaver` genuinely stays on top of everything.
    var keepOnTop: Bool {
        get { panel.level == .screenSaver }
        set {
            panel.level = newValue ? .screenSaver : .floating
            UserDefaults.standard.set(newValue, forKey: Self.keepOnTopKey)
        }
    }

    static let keepOnTopKey = "SillKeepOnTop"

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let wasVisible = panel.isVisible

        // Remember who was in front before we take key focus — "Send to App" needs it.
        // Deliberately the cheap version: the full `frontmostSource()` walks the
        // accessibility tree for a page URL, which can block the main thread for seconds
        // and was making the panel feel frozen every single time it opened.
        if let app = NSWorkspace.shared.frontmostApplication,
           let name = app.localizedName, name != "Sill" {
            state.targetApp = Source(appName: name, bundleID: app.bundleIdentifier)
        }
        // Pick up anything edited in another app before we show stale contents.
        store.reloadIfChangedOnDisk()
        rehomeIfOffscreen()
        panel.orderFrontRegardless()

        // Only grab the keyboard when the panel is arriving. Calling makeKey() on every
        // capture pulled the caret out of the app you were reading — the exact thing a
        // nonactivating panel exists to avoid.
        guard !wasVisible else { return }
        panel.makeKey()

        // A stale search or focused section would hide the thing you just captured.
        state.query = ""
        state.selection = []
        state.focusComposerToken &+= 1
    }

    /// Also runs on screen changes, not only on show: a display unplugged while the panel
    /// is visible would otherwise strand it off-screen, and the autosaved frame would
    /// restore it off-screen on the next launch too.
    @objc func rehomeIfOffscreen() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            dockToRightEdge()
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Sits against the right edge of whichever screen holds the pointer.
    private func dockToRightEdge() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let inset: CGFloat = 16
        let height = min(visible.height - inset * 2, 720)
        let frame = NSRect(
            x: visible.maxX - Theme.panelWidth - inset,
            y: visible.midY - height / 2,
            width: Theme.panelWidth,
            height: height
        )
        panel.setFrame(frame, display: false)
    }
}

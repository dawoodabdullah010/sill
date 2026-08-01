import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let state = PanelState()
    private var controller: PanelController!
    private let shift = DoubleShiftMonitor()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var trustItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        controller = PanelController(store: store, state: state)
        state.showShortcuts = { [weak self] in self?.showShortcuts() }
        buildStatusItem()

        // Anything already on the clipboard at launch is not a new capture.
        Capture.markClipboardSeen()

        shift.onTrigger = { [weak self] in self?.capture() }
        shift.start()

        controller.show()
    }

    /// Double-Shift: take whatever is highlighted, and remember where it came from.
    private func capture() {
        #if DEBUG
        NSLog("Sill: gesture fired. trusted=\(Capture.isTrusted)")
        #endif
        let source = Capture.frontmostSource()

        // Without Accessibility the app still works — it takes what you last copied.
        // Ask at most once per launch, and never block the capture on the answer.
        // ("Ask once ever" was wrong: an ad-hoc build loses the grant on every rebuild,
        // which left the app permanently mute.)
        if Capture.isTrusted {
            Capture.hasEverBeenTrusted = true
        } else if Capture.grantIsStale {
            // Asking again is useless here — macOS already has a decision on file for this
            // bundle, so no prompt appears and the user sees nothing happen. Tell them what
            // actually fixes it.
            // Stop here. Falling through filed the clipboard instead and then overwrote
            // this warning with "Captured from X" — so the user was told the opposite of
            // what happened, and got stale content in their list.
            state.flash("Accessibility expired — switch Sill off and on in Settings")
            controller.show()
            return
        } else if !askedForTrustThisLaunch {
            askedForTrustThisLaunch = true
            Capture.requestTrust()
        }

        // With Accessibility on, the gesture means "take what I've selected" — full stop.
        // The clipboard is only consulted when there is no selection.
        //
        // Order matters here and got this wrong twice. Checking the clipboard first meant
        // an old screenshot won every time. Then gating that on "did the clipboard change"
        // failed too, because our own synthesised ⌘C *and* the restore afterwards each
        // bump the clipboard's change counter — so the next capture always looked fresh
        // and the stale image came back. Hence: selection first, clipboard never guessed at.
        if Capture.isTrusted {
            Capture.captureSelection { [weak self] text in
                guard let self else { return }
                Capture.markClipboardSeen()          // after the restore, not before
                if let text, !text.isEmpty {
                    self.file(text, from: source)
                } else if Capture.wasBusy {
                    // A second gesture landed while the first was still polling. Saying
                    // "Nothing selected" made people tap again and file a duplicate.
                    Capture.wasBusy = false
                } else {
                    self.state.flash("Nothing selected")
                    self.controller.show()
                }
            }
            return
        }

        // No Accessibility: the clipboard is all we have, so it must be something new.
        guard !Capture.clipboardIsUnchanged() else {
            state.flash("Nothing new copied — press ⌘C first")
            controller.show()
            return
        }
        fileClipboardFallback(from: source)
    }

    /// Whatever is on the clipboard — an image if there is one, otherwise text.
    private func fileClipboardFallback(from source: Source?) {
        Capture.markClipboardSeen()
        if let png = Capture.clipboardImage() {
            if store.addImage(png, caption: nil, to: state.activeSection, source: source) {
                state.flash("Screenshot captured")
            }
            controller.show()
            return
        }
        file(Capture.clipboardText(), from: source)
    }

    private var askedForTrustThisLaunch = false

    private func file(_ text: String?, from source: Source?) {
        guard let text, !text.isEmpty else {
            state.flash(Capture.isTrusted
                        ? "Nothing selected"
                        : "Nothing copied yet — press ⌘C first, or turn on Accessibility")
            controller.show()
            return
        }
        _ = withAnimation(Theme.reduceMotion ? nil : Theme.spring) {
            self.store.add(text, kind: .note, to: state.activeSection, source: source)
        }
        state.flash(source.map { "Captured from \($0.appName)" } ?? "Captured")
        controller.show()
    }

    /// Without a main menu, AppKit has nowhere to dispatch the standard editing key
    /// equivalents — so ⌘V, ⌘A and ⌘Z simply do nothing inside the composer. An agent
    /// app has no visible menu bar, but it still needs this to exist.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")

        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")

        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Plain word instead of a glyph — it reads as itself, and a menu-bar symbol nobody
        // recognises is just decoration.
        statusItem.button?.title = "Sill"
        statusItem.button?.font = .systemFont(ofSize: 13, weight: .regular)

        let menu = NSMenu()
        menu.delegate = self

        // Title is set in menuWillOpen — a static "Show Sill" is a lie half the time.
        toggleItem = menu.addItem(withTitle: "Show Sill", action: #selector(toggle),
                                  keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(.separator())

        let reveal = menu.addItem(withTitle: "Open Notes Folder",
                                  action: #selector(revealFolder), keyEquivalent: "")
        reveal.target = self

        // Lists, Clear Done, Keep on Top and Shortcuts live in the panel's own ··· menu —
        // that's where you are when you want them. The status bar keeps only the things
        // you need when the panel isn't in front of you.

        // Always present, so its state is readable rather than inferred from its absence.
        trustItem = menu.addItem(withTitle: "Turn On Accessibility…",
                                 action: #selector(requestTrust), keyEquivalent: "")
        trustItem.target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sill", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func toggle() { controller.toggle() }

    @objc private func revealFolder() {
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Store.folder)
    }

    @objc private func requestTrust() {
        guard !Capture.isTrusted else {
            // Already on — take them to the row so they can see or change it.
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        Capture.requestTrust()
    }





    @objc private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Sill shortcuts"
        alert.informativeText = """
            ⇧ ⇧          Capture the selection, or a screenshot on the clipboard
            ↑ ↓          Move through the list
            Space        Mark done
            ↩            Edit the selected item
            ⌘C           Copy  ·  ⇧⌘C copies several as a list
            ⌘↩           Send back to the app you came from
            ⌘Z / ⇧⌘Z     Undo · Redo
            ⌘F           Search   ·   ⌘K  one list at a time
            ⌫            Delete
            Esc          Clear selection, then close
            # Name ↩     Start a new list
            """
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Menu titles are computed on open, so they always describe what will happen.
    func menuWillOpen(_ menu: NSMenu) {
        toggleItem.title = controller.isVisible ? "Hide Sill" : "Show Sill"
        trustItem.title = Capture.isTrusted
            ? "Accessibility is on ✓"
            : "Turn On Accessibility…"
        trustItem.toolTip = Capture.isTrusted
            ? "Sill can read your selection directly. Click to open the setting."
            : "Optional. Lets Shift-Shift grab the selection without you pressing ⌘C first."
    }
}

// NSApplication.delegate is a weak reference, so the delegate needs to outlive this scope.
nonisolated(unsafe) var sillDelegate: AppDelegate?

let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    sillDelegate = delegate
    app.delegate = delegate
    // .accessory = no Dock icon, no menu bar takeover. Sill is furniture, not an app you "open".
    // SILL_REGULAR_APP=1 forces a normal Dock app — the only way UI-automation tooling can
    // see it by name. DEBUG only: a release build must not let an env var change how the app
    // presents itself.
    #if DEBUG
    app.setActivationPolicy(
        ProcessInfo.processInfo.environment["SILL_REGULAR_APP"] == "1" ? .regular : .accessory
    )
    #else
    app.setActivationPolicy(.accessory)
    #endif
}
app.run()

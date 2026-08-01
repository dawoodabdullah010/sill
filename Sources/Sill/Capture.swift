import AppKit
import ApplicationServices

/// Getting text in, and getting it back out.
///
/// Two tiers, and the app is fully usable on the first:
///
/// 1. **No permissions.** You press ⌘C yourself; Sill reads the clipboard.
/// 2. **With Accessibility.** Sill presses ⌘C for you, and can paste back into
///    the app you were in. Synthesising a keystroke is what needs the permission,
///    not the reading.
enum Capture {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// What you're looking at right now — recorded before we touch anything.
    static func frontmostSource() -> Source? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName, name != "Sill" else { return nil }
        return Source(appName: name,
                      bundleID: app.bundleIdentifier,
                      url: isBrowser(app.bundleIdentifier)
                           ? currentPageURL(pid: app.processIdentifier)
                           : nil)
    }

    /// Only browsers get the accessibility-tree walk.
    ///
    /// It is a 600-node search on the main thread, and it switches on
    /// `AXEnhancedUserInterface`, which is known to make Electron and Office apps
    /// re-lay-out their windows. Neither is worth doing to an app that has no address bar.
    private static func isBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return ["com.apple.safari", "com.google.chrome", "com.google.chrome.canary",
                "com.microsoft.edgemac", "company.thebrowser.browser",
                "com.brave.browser", "org.mozilla.firefox", "com.vivaldi.vivaldi",
                "com.operasoftware.opera", "ai.perplexity.comet", "com.apple.safaritechnologypreview"]
            .contains(id)
    }

    /// Reads the address of the page in front, by finding the web area in the app's
    /// accessibility tree. Works for any browser that exposes `AXURL` — Safari, Chrome,
    /// Arc, Edge, Brave — and returns nil for native apps, which have no address to read.
    static func currentPageURL(pid: pid_t) -> String? {
        guard isTrusted else { return nil }

        let app = AXUIElementCreateApplication(pid)
        // Short: this runs on the main thread, and a hung app must never stall a capture.
        AXUIElementSetMessagingTimeout(app, 0.12)

        // Chrome, Electron and anything Chromium-based expose an empty window to the
        // accessibility system until an assistive client explicitly switches their web
        // tree on. Both flags are undocumented but long-standing; setting them is
        // harmless on apps that don't recognise them, and without them there is simply
        // no URL anywhere in the tree to find.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }

        return findURL(from: unsafeBitCast(window, to: AXUIElement.self))
    }

    /// Breadth-first with a node budget.
    ///
    /// Breadth-first matters: the web area sits shallow but is often a late sibling, so a
    /// depth-first walk burrows into toolbars and tab strips and gives up before reaching
    /// it. The budget keeps a pathological tree from turning a capture into a hang.
    private static func findURL(from root: AXUIElement) -> String? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        let budget = 150
        let deadline = Date().addingTimeInterval(0.6)   // hard ceiling, whatever happens

        while !queue.isEmpty, visited < budget, Date() < deadline {
            let element = queue.removeFirst()
            visited += 1

            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef) == .success {
                if let url = urlRef as? URL { return url.absoluteString }
                if let string = urlRef as? String, string.contains("://") { return string }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(40))
            }
        }
        return nil
    }

    /// Bring an app forward without navigating it.
    @discardableResult
    static func activateApp(_ source: Source) -> Bool {
        guard let id = source.bundleID,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        else { return false }
        return running.activate(options: [.activateAllWindows])
    }

    /// Go back to where an item came from — the exact page if we have one, else the app.
    @discardableResult
    static func reveal(_ source: Source) -> Bool {
        if let raw = source.url, let url = URL(string: raw) {
            return NSWorkspace.shared.open(url)
        }
        if let id = source.bundleID,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            return running.activate(options: [.activateAllWindows])
        }
        return false
    }

    /// The real capture path: read the highlighted text without disturbing anything.
    ///
    /// Tried in order —
    /// 1. Accessibility, reading the selection straight from the focused element.
    ///    Nothing is copied, nothing is typed, your clipboard is untouched.
    /// 2. A synthesised ⌘C for apps that don't expose their selection (some
    ///    Electron apps), with the clipboard saved and put back afterwards.
    /// 3. Whatever you last copied — the no-permission fallback.
    /// Guards against a second capture starting while one is still polling. Without this,
    /// two quick triggers snapshot each other's clipboard state and the user's original
    /// clipboard is permanently replaced.
    private static var isCapturing = false

    /// Order matters, and it is the opposite of what looks elegant.
    ///
    /// `AXSelectedText` reads the *focused* element. In a browser or an Electron app the
    /// focused element is usually the message composer, not the transcript you highlighted —
    /// so it returns that element's stale selection and you get a chunk of some older
    /// message, often truncated mid-word. Observed and reproduced in Claude's UI.
    ///
    /// A synthesised ⌘C returns exactly what is visually selected, because it is literally
    /// what ⌘C would copy. So that goes first whenever we're allowed to do it, and the AX
    /// read is only a fallback for apps where the copy yields nothing.
    static func captureSelection(completion: @escaping (String?) -> Void) {
        guard !isCapturing else { completion(nil); return }

        if isTrusted {
            isCapturing = true
            selectionViaSynthesizedCopy { copied in
                isCapturing = false
                completion(copied ?? selectedTextViaAccessibility() ?? clipboardText())
            }
            return
        }
        completion(clipboardText())
    }

    /// Reads `AXSelectedText` from whatever element has keyboard focus.
    static func selectedTextViaAccessibility() -> String? {
        guard isTrusted else { return nil }

        let system = AXUIElementCreateSystemWide()
        // Without a timeout this is a synchronous IPC call to the frontmost app on the
        // main thread — a wedged app would beachball Sill on every capture.
        AXUIElementSetMessagingTimeout(system, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }

        let element = unsafeBitCast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextAttribute as CFString,
                                            &valueRef) == .success,
              let text = valueRef as? String
        else { return nil }

        return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Shows the standard macOS permission sheet. Only ever called from the menu,
    /// never on launch — the app works without it.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// A screenshot or any image on the clipboard, normalised to PNG.
    ///
    /// Covers three routes, because people reach for all of them:
    /// `⌃⌘⇧4` (screenshot straight to the clipboard), copy-image-from-a-browser,
    /// and copying the *file* a plain `⌘⇧4` left on the Desktop.
    static func clipboardImage() -> Data? {
        let pasteboard = NSPasteboard.general

        // Prefer real PNG data when it's already there — no recompression.
        if let png = pasteboard.data(forType: .png) { return png }

        // An image file copied in Finder arrives as a file URL, not as image data.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let file = urls.first(where: { ["png", "jpg", "jpeg", "heic", "gif", "tiff"]
                                            .contains($0.pathExtension.lowercased()) }),
           let image = NSImage(contentsOf: file),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }

        // Otherwise take whatever image representation exists and convert.
        guard let tiff = pasteboard.data(forType: .tiff)
                ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Has anything been copied since the last time we looked?
    ///
    /// Without Accessibility a capture just reads the clipboard, so tapping the gesture
    /// twice with nothing newly copied would file the same text again and again. This is
    /// what stops that.
    private static var lastSeenChangeCount = -1

    static func clipboardIsUnchanged() -> Bool {
        NSPasteboard.general.changeCount == lastSeenChangeCount
    }

    static func markClipboardSeen() {
        lastSeenChangeCount = NSPasteboard.general.changeCount
    }

    static func clipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Tier 2: copy the current selection without disturbing the user's clipboard.
    ///
    /// Restoring the clipboard matters more than it looks. If capturing silently
    /// ate whatever you had copied, the app would feel broken in a way nobody
    /// bothers to report — they just stop using it.
    static func selectionViaSynthesizedCopy(completion: @escaping (String?) -> Void) {
        guard isTrusted else { completion(nil); return }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        post(keyCode: 8, flags: .maskCommand)   // 8 == "c"

        // Poll briefly; the target app fills the pasteboard asynchronously.
        poll(pasteboard, changingFrom: before, attempt: 0) { copied in
            restore(saved, to: pasteboard)
            completion(copied)
        }
    }

    /// Paste text into the app the user came from.
    ///
    /// The target must be re-activated first. Sill's panel holds key focus in order to
    /// receive ⌘↩, and the WindowServer delivers synthesised keystrokes to the *key
    /// window* — so posting ⌘V without this pastes into Sill's own composer.
    static func send(_ text: String, to target: Source?) -> Bool {
        guard isTrusted else { return false }
        // Activate the app, don't open its URL — opening would spawn a new tab instead of
        // returning to the window whose input field we're about to paste into.
        guard let target, activateApp(target) else { return false }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Let the target actually come forward before typing into it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            post(keyCode: 9, flags: .maskCommand)   // 9 == "v"
            // Generous window: a busy Electron app can read the pasteboard late, and
            // restoring too early pastes the user's *old* clipboard into their chat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                restore(saved, to: pasteboard)
            }
        }
        return true
    }

    // MARK: - Pasteboard preservation

    private struct Saved { let items: [[NSPasteboard.PasteboardType: Data]] }

    private static func snapshot(_ pasteboard: NSPasteboard) -> Saved {
        // Promised/lazy flavours (a file promise from Finder or Mail, an image an app
        // vends on demand) return nil data. Keeping the empty dictionaries would make
        // the snapshot look non-empty, and restoring it would wipe the clipboard.
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy.isEmpty ? nil : copy
        }
        return Saved(items: items)
    }

    private static func restore(_ saved: Saved, to pasteboard: NSPasteboard) {
        // Nothing usable was captured, so leave whatever is there alone rather than
        // clearing it. Losing the user's clipboard is worse than a stale capture.
        guard !saved.items.isEmpty else { return }
        pasteboard.clearContents()
        let rebuilt = saved.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(rebuilt)
    }

    private static func poll(_ pasteboard: NSPasteboard,
                             changingFrom before: Int,
                             attempt: Int,
                             completion: @escaping (String?) -> Void) {
        guard attempt < 20 else { completion(nil); return }   // ~600ms ceiling
        if pasteboard.changeCount != before {
            completion(pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            poll(pasteboard, changingFrom: before, attempt: attempt + 1, completion: completion)
        }
    }

    private static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

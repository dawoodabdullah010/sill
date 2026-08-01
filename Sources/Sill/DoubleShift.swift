import AppKit

/// Fires when Shift is tapped twice in quick succession.
///
/// **Observed** to work with no permissions on macOS 26.5: with
/// `AXIsProcessTrusted() == false`, `CGEvent.tapCreate` is refused for a keyDown mask
/// but admitted for `.flagsChanged`, because modifier events carry no typed character.
///
/// This is undocumented. Apple's `addGlobalMonitorForEvents` documentation says
/// key-related events require accessibility, and `.flagsChanged` is a key-related mask —
/// so we are relying on a gap between the documented contract and the shipped
/// implementation. It looks like a deliberate carve-out rather than a leak, but Apple
/// owes us nothing here and it could close.
///
/// It is also **not** collision-free, contrary to an earlier claim in this file:
/// JetBrains IDEs (IntelliJ, PyCharm, WebStorm, CLion, Rider, Android Studio) bind
/// double-Shift to Search Everywhere. That is squarely this app's audience, so the
/// gesture needs to be rebindable or suppressible per-app.
final class DoubleShiftMonitor {
    var onTrigger: () -> Void = {}

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastTapEnded: TimeInterval = 0
    private var shiftDown = false

    /// Two taps must land inside this window.
    private let window: TimeInterval = 0.4

    /// A tap is a quick press-and-release. Holding Shift to type a capital, or to
    /// range-select with a click, takes longer than this and is not a tap.
    private let maxTapDuration: TimeInterval = 0.35

    private var tapStarted: TimeInterval = 0

    private static let shiftKeyCodes: Set<UInt16> = [56, 60]  // left, right

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
        }
        // The global monitor is silent while our own panel holds focus, so mirror it locally.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil
        localMonitor = nil
    }

    deinit { stop() }

    private func handle(_ event: NSEvent) {
        guard Self.shiftKeyCodes.contains(event.keyCode) else {
            // Any other modifier cancels a half-finished gesture, so ⇧⌘ combos never trigger us.
            shiftDown = false
            lastTapEnded = 0
            return
        }

        let isDown = event.modifierFlags.contains(.shift)

        // Shift with another modifier held is part of a real shortcut, not our gesture.
        let others: NSEvent.ModifierFlags = [.command, .option, .control]
        if !event.modifierFlags.intersection(others).isEmpty {
            shiftDown = false
            lastTapEnded = 0
            return
        }

        let now = ProcessInfo.processInfo.systemUptime

        if isDown {
            shiftDown = true
            tapStarted = now
            return
        }

        guard shiftDown else { return }
        shiftDown = false

        let held = now - tapStarted

        // Held too long to be a tap — that's a capital letter or a Shift-click.
        guard held <= maxTapDuration else {
            NSLog("Sill: shift held %.2fs — not a tap", held)
            lastTapEnded = 0
            return
        }

        // Was anything typed between the two taps? If so this is "Hi There", not the
        // gesture. `secondsSinceLastEventType` is a query, not an event tap, so it needs
        // no permission — but it can report 0 in some states, so treat a suspiciously
        // small value as "no information" rather than as a veto.
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                               eventType: .keyDown)
        let gap = now - lastTapEnded
        let typedBetween = sinceKey > 0.001 && sinceKey < gap

        NSLog("Sill: tap held=%.2f gap=%.2f sinceKey=%.2f typedBetween=%@",
              held, gap, sinceKey, typedBetween ? "yes" : "no")

        if lastTapEnded > 0, gap <= window, !typedBetween {
            lastTapEnded = 0
            onTrigger()
        } else {
            lastTapEnded = now
        }
    }
}

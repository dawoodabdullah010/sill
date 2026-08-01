import SwiftUI
import AppKit

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green:   CGFloat((rgb >> 8)  & 0xFF) / 255,
                  blue:    CGFloat( rgb        & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    /// Resolves per appearance so every surface is correct in dark mode without a second palette.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

/// Warm neutrals in the spirit of emilkowal.ski. No brand accent — emphasis is ink and weight.
///
/// The panel is the **darker ground** and cards are the **lighter figures** on it. The first
/// version had this backwards: a near-white card on a near-white panel is a 1.035:1 contrast
/// ratio, which is no edge at all, and the hairline added to rescue it sat at 1.16:1 — below
/// the threshold where a 1px line is reliably seen. Cards now separate by fill, not by border.
enum Theme {
    static let bg          = Color.dynamic(light: 0xF2F1EF, dark: 0x1A1A19)  // panel ground
    static let surface     = Color.dynamic(light: 0xFDFDFC, dark: 0x262624)  // card
    static let surfaceHover = Color.dynamic(light: 0xFFFFFF, dark: 0x2E2E2C)
    /// Selection is carried by fill alone — no ring, no side bar. So it has to be a real
    /// step away from both the resting card and the hover state, or a multi-selection
    /// reads as nothing at all.
    static let selected     = Color.dynamic(light: 0xE6E2D9, dark: 0x45443F)
    static let ink         = Color.dynamic(light: 0x21201C, dark: 0xEEEEEC)
    static let muted       = Color.dynamic(light: 0x63635E, dark: 0x8D8D86)
    static let hairline    = Color.dynamic(light: 0xE4E2DF, dark: 0x323230)  // rules only, never cards

    static let panelWidth:  CGFloat = 380
    static let panelRadius: CGFloat = 20
    static let cardRadius:  CGFloat = 12
    static let cardGap:     CGFloat = 12   // never smaller than `pad`, or cards fuse into a block
    static let sectionGap:  CGFloat = 24   // above a section header
    static let pad:         CGFloat = 12   // inside a card
    static let panelPad:    CGFloat = 14   // panel edge inset

    // Motion. Reduce Motion is honoured at the call site.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let quick  = Animation.easeOut(duration: 0.16)
    static let hover  = Animation.easeOut(duration: 0.12)
    static let toggle = Animation.easeOut(duration: 0.14)

    // Taken from the interactive mockup, so the app matches what was signed off.
    /// The strikethrough sweeping left to right.
    static let strike = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.14)
    /// The row leaving: fade + 10pt to the right + collapse.
    static let leave  = Animation.easeOut(duration: 0.20)

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

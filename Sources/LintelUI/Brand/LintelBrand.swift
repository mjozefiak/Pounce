import AppKit
import SwiftUI

/// The brand colours as plain sRGB numbers, so tests can check their contrast without AppKit.
/// Source: `.ai/prototypes/lintel-brand/index.html` (Verdigris accent, warm neutrals, flat colour: no
/// gradients and no glow).
public nonisolated enum BrandPalette {
    /// `brand.accent`: fills, the caret, bars and other graphics (needs 3:1 against what is behind it).
    public static let accentLight: UInt32 = 0x267C6C
    public static let accentDark: UInt32 = 0x6BBDAB
    /// `brand.accent.text`: the accent used as text (needs 4.5:1). The plain accent is only 3.2:1 on a selected
    /// row in the light theme, so text gets a darker value there.
    public static let accentTextLight: UInt32 = 0x036152
    public static let accentTextDark: UInt32 = 0x6BBDAB
    /// Text on an accent fill (primary buttons, the selected filter chip).
    public static let onAccentLight: UInt32 = 0xFFFFFF
    public static let onAccentDark: UInt32 = 0x161310
    /// `brand.accent.secondary`: the mark's ring and titles on brand pages.
    public static let inkLight: UInt32 = 0x191610
    public static let inkDark: UInt32 = 0xF1EEE9
    /// Brand surfaces (landing page, About art). App windows keep the system fills.
    public static let surfaceLight: UInt32 = 0xF6F3ED
    public static let surfaceDark: UInt32 = 0x161310
    /// `status.ok`, `status.attention`, `status.error`: the status icons and dots of the main window (the
    /// prototype's `--ok`, `--att`, `--er`). Graphics only (3:1); status text stays in the label colour.
    public static let statusOkLight: UInt32 = 0x1E8E3E
    public static let statusOkDark: UInt32 = 0x32D74B
    public static let statusAttentionLight: UInt32 = 0xB25E00
    public static let statusAttentionDark: UInt32 = 0xFF9F0A
    public static let statusErrorLight: UInt32 = 0xD70015
    public static let statusErrorDark: UInt32 = 0xFF6961
    /// The glyph inside a filled status circle (the Settings banner, prototype `.bn .g`): white in the light
    /// theme, the dark brand surface in the dark one. Graphics (3:1 against every status fill).
    public static let onStatusLight: UInt32 = 0xFFFFFF
    public static let onStatusDark: UInt32 = 0x161310

    /// WCAG 2.x contrast ratio between two opaque sRGB colours.
    public static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `foreground` at `alpha` over `background`, as an opaque colour.
    public static func blend(_ foreground: UInt32, alpha: Double, over background: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let front = Double((foreground >> shift) & 0xFF)
            let back = Double((background >> shift) & 0xFF)
            return UInt32((front * alpha + back * (1 - alpha)).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}

/// The brand colours as dynamic colours that follow the appearance.
@MainActor
public enum LintelBrand {
    /// How strongly the accent tints a selected row (light, dark).
    nonisolated public static let selectionTintAlpha: (light: Double, dark: Double) = (0.14, 0.18)

    public static let accentColor = dynamic("LintelAccent", BrandPalette.accentLight, BrandPalette.accentDark)
    public static let accentTextColor = dynamic(
        "LintelAccentText", BrandPalette.accentTextLight, BrandPalette.accentTextDark)
    public static let onAccentColor = dynamic("LintelOnAccent", BrandPalette.onAccentLight, BrandPalette.onAccentDark)
    public static let selectionTintColor = NSColor(name: "LintelSelectionTint") { appearance in
        isDark(appearance)
            ? color(BrandPalette.accentDark, alpha: selectionTintAlpha.dark)
            : color(BrandPalette.accentLight, alpha: selectionTintAlpha.light)
    }

    public static let inkColor = dynamic("LintelInk", BrandPalette.inkLight, BrandPalette.inkDark)
    public static let ink = Color(nsColor: inkColor)

    public static let accent = Color(nsColor: accentColor)
    public static let accentText = Color(nsColor: accentTextColor)
    public static let onAccent = Color(nsColor: onAccentColor)
    public static let selectionTint = Color(nsColor: selectionTintColor)

    public static let statusOkColor = dynamic("LintelStatusOk", BrandPalette.statusOkLight, BrandPalette.statusOkDark)
    public static let statusAttentionColor = dynamic(
        "LintelStatusAttention", BrandPalette.statusAttentionLight, BrandPalette.statusAttentionDark)
    public static let statusErrorColor = dynamic(
        "LintelStatusError", BrandPalette.statusErrorLight, BrandPalette.statusErrorDark)

    public static let statusOk = Color(nsColor: statusOkColor)
    public static let statusAttention = Color(nsColor: statusAttentionColor)
    public static let statusError = Color(nsColor: statusErrorColor)

    public static let onStatusColor = dynamic("LintelOnStatus", BrandPalette.onStatusLight, BrandPalette.onStatusDark)
    public static let onStatus = Color(nsColor: onStatusColor)

    nonisolated private static func dynamic(_ name: String, _ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: name) { appearance in color(isDark(appearance) ? dark : light) }
    }

    nonisolated private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    nonisolated private static func color(_ hex: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    /// The brand accent for every control below: toggles, links, prominent buttons.
    public func lintelBrand() -> some View { tint(LintelBrand.accent) }
}

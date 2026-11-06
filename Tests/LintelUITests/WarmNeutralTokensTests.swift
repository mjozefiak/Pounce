import AppKit
import LintelUI
import Testing

/// The main window's warm neutrals are the prototype's tokens (`.ai/prototypes/lintel-app/index.html`, `.light`
/// and `.dark`), as numbers and as the dynamic colours each appearance resolves.
@Suite struct WarmNeutralTokensTests {
    /// One prototype token: the CSS value in light and dark (rgb, alpha).
    struct Token: Sendable, CustomTestStringConvertible {
        let css: String
        let light: (rgb: UInt32, alpha: Double)
        let dark: (rgb: UInt32, alpha: Double)
        var testDescription: String { css }
    }

    static let prototype: [Token] = [
        Token(css: "--win", light: (0xF6F4F0, 1), dark: (0x1C1915, 1)),
        Token(css: "--side", light: (0xE7E4DE, 1), dark: (0x141210, 1)),
        Token(css: "--card", light: (0xFFFFFF, 1), dark: (0x26221E, 1)),
        Token(css: "--sec", light: (0x6B645A, 1), dark: (0xA39B8F, 1)),
        // rgba(25,22,16,.11) / rgba(255,255,255,.11)
        Token(css: "--hair", light: (0x191610, 0.11), dark: (0xFFFFFF, 0.11)),
        // rgba(25,22,16,.06) / rgba(255,255,255,.08)
        Token(css: "--fill", light: (0x191610, 0.06), dark: (0xFFFFFF, 0.08)),
        // rgba(38,124,108,.14) / rgba(107,189,171,.20)
        Token(css: "--tint", light: (0x267C6C, 0.14), dark: (0x6BBDAB, 0.20)),
    ]

    @MainActor
    static func colour(_ css: String) -> NSColor? {
        switch css {
        case "--win": LintelBrand.windowBackgroundColor
        case "--side": LintelBrand.sidebarBackgroundColor
        case "--card": LintelBrand.cardColor
        case "--sec": LintelBrand.secondaryTextColor
        case "--hair": LintelBrand.hairlineColor
        case "--fill": LintelBrand.fillColor
        case "--tint": LintelBrand.windowSelectionTintColor
        default: nil
        }
    }

    @Test func thePaletteNumbersAreThePrototypes() {
        #expect(BrandPalette.windowLight == 0xF6F4F0 && BrandPalette.windowDark == 0x1C1915)
        #expect(BrandPalette.sidebarLight == 0xE7E4DE && BrandPalette.sidebarDark == 0x141210)
        #expect(BrandPalette.cardLight == 0xFFFFFF && BrandPalette.cardDark == 0x26221E)
        #expect(BrandPalette.secondaryTextLight == 0x6B645A && BrandPalette.secondaryTextDark == 0xA39B8F)
        #expect(BrandPalette.hairlineLight == 0x191610 && BrandPalette.hairlineDark == 0xFFFFFF)
        #expect(BrandPalette.hairlineAlpha == (0.11, 0.11))
        #expect(BrandPalette.fillLight == 0x191610 && BrandPalette.fillDark == 0xFFFFFF)
        #expect(BrandPalette.fillAlpha == (0.06, 0.08))
        #expect(BrandPalette.windowSelectionTintAlpha == (0.14, 0.20))
    }

    /// `--ink` and `--accent` are the existing brand tokens; the main window uses them unchanged.
    @Test func theSharedTokensMatchThePrototype() {
        #expect(BrandPalette.inkLight == 0x191610 && BrandPalette.inkDark == 0xF1EEE9)
        #expect(BrandPalette.accentLight == 0x267C6C && BrandPalette.accentDark == 0x6BBDAB)
    }

    @MainActor
    @Test(arguments: prototype)
    func eachDynamicColourResolvesToThePrototypeValue(_ token: Token) throws {
        let colour = try #require(Self.colour(token.css))
        for (name, expected) in [(NSAppearance.Name.aqua, token.light), (.darkAqua, token.dark)] {
            let appearance = try #require(NSAppearance(named: name))
            var rgb: UInt32 = 0
            var alpha = -1.0
            appearance.performAsCurrentDrawingAppearance {
                guard let resolved = colour.usingColorSpace(.sRGB) else { return }
                func byte(_ value: CGFloat) -> UInt32 { UInt32((max(0, min(1, value)) * 255).rounded()) }
                rgb =
                    byte(resolved.redComponent) << 16 | byte(resolved.greenComponent) << 8
                    | byte(resolved.blueComponent)
                alpha = Double(resolved.alphaComponent)
            }
            #expect(rgb == expected.rgb, "\(token.css) \(name.rawValue): \(String(rgb, radix: 16))")
            #expect(abs(alpha - expected.alpha) < 0.001, "\(token.css) \(name.rawValue) alpha \(alpha)")
        }
    }

    /// The launcher keeps the brand prototype's selection (`.18` in dark); only the main window uses `--tint`.
    @Test func theLauncherSelectionIsUnchanged() {
        #expect(LintelBrand.selectionTintAlpha == (0.14, 0.18))
    }
}

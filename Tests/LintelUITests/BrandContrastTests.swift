import AppKit
import LintelUI
import Testing

@Suite struct BrandContrastTests {
    // Worst-case backgrounds under the glass panel, from the brand design: light glass over a dark wallpaper and
    // dark glass over a light one, and the selected row (the accent tint over that glass).
    private let lightGlass: UInt32 = 0xE1DFDC
    private let darkGlass: UInt32 = 0x2D2924
    private var lightSelected: UInt32 {
        BrandPalette.blend(BrandPalette.accentLight, alpha: LintelBrand.selectionTintAlpha.light, over: lightGlass)
    }
    private var darkSelected: UInt32 {
        BrandPalette.blend(BrandPalette.accentDark, alpha: LintelBrand.selectionTintAlpha.dark, over: darkGlass)
    }

    @Test func accentTextIsReadableOnTheGlassAndOnTheSelectedRow() {
        #expect(BrandPalette.contrast(BrandPalette.accentTextLight, lightGlass) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.accentTextLight, lightSelected) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.accentTextDark, darkGlass) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.accentTextDark, darkSelected) >= 4.5)
    }

    @Test func theAccentAsAGraphicHasThreeToOne() {
        // The caret, the selection bar and the level bars.
        #expect(BrandPalette.contrast(BrandPalette.accentLight, lightGlass) >= 3)
        #expect(BrandPalette.contrast(BrandPalette.accentLight, lightSelected) >= 3)
        #expect(BrandPalette.contrast(BrandPalette.accentDark, darkGlass) >= 3)
        #expect(BrandPalette.contrast(BrandPalette.accentDark, darkSelected) >= 3)
    }

    @Test func textOnAnAccentFillIsReadable() {
        // Primary buttons and the selected filter chip.
        #expect(BrandPalette.contrast(BrandPalette.onAccentLight, BrandPalette.accentLight) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.onAccentDark, BrandPalette.accentDark) >= 4.5)
    }

    @Test func theBrandSurfacesKeepTheInkReadable() {
        #expect(BrandPalette.contrast(BrandPalette.inkLight, BrandPalette.surfaceLight) >= 7)
        #expect(BrandPalette.contrast(BrandPalette.inkDark, BrandPalette.surfaceDark) >= 7)
        #expect(BrandPalette.contrast(BrandPalette.accentTextLight, BrandPalette.surfaceLight) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.accentTextDark, BrandPalette.surfaceDark) >= 4.5)
    }

    /// The status colours are graphics (banner icons, status dots), so they need 3:1 against the window
    /// backgrounds they sit on: the system window fill and the brand surfaces.
    @Test func eachStatusColourHasThreeToOneOnItsBackground() {
        let lightWindow: UInt32 = 0xECECEC
        let darkWindow: UInt32 = 0x323232
        let pairs: [(name: String, light: UInt32, dark: UInt32)] = [
            ("ok", BrandPalette.statusOkLight, BrandPalette.statusOkDark),
            ("attention", BrandPalette.statusAttentionLight, BrandPalette.statusAttentionDark),
            ("error", BrandPalette.statusErrorLight, BrandPalette.statusErrorDark),
        ]
        for pair in pairs {
            for background in [lightWindow, BrandPalette.surfaceLight, lightGlass] {
                #expect(BrandPalette.contrast(pair.light, background) >= 3, "status.\(pair.name) light")
            }
            for background in [darkWindow, BrandPalette.surfaceDark, darkGlass] {
                #expect(BrandPalette.contrast(pair.dark, background) >= 3, "status.\(pair.name) dark")
            }
        }
    }

    @Test func theStatusTokensKeepTheirValues() {
        #expect(BrandPalette.statusOkLight == 0x1E8E3E && BrandPalette.statusOkDark == 0x32D74B)
        #expect(BrandPalette.statusAttentionLight == 0xB25E00 && BrandPalette.statusAttentionDark == 0xFF9F0A)
        #expect(BrandPalette.statusErrorLight == 0xD70015 && BrandPalette.statusErrorDark == 0xFF6961)
    }
}

@Suite struct StatusBannerContrastTests {
    /// The Settings banner's glyph sits on its own level's tint over the window: it keeps 3:1 there.
    @Test func eachStatusGlyphHasThreeToOneOnItsBannerTint() {
        let lightWindow: UInt32 = 0xECECEC
        let darkWindow: UInt32 = 0x323232
        let alpha = LintelBrand.statusTintAlpha
        let pairs: [(name: String, light: UInt32, dark: UInt32)] = [
            ("ok", BrandPalette.statusOkLight, BrandPalette.statusOkDark),
            ("attention", BrandPalette.statusAttentionLight, BrandPalette.statusAttentionDark),
            ("error", BrandPalette.statusErrorLight, BrandPalette.statusErrorDark),
        ]
        for pair in pairs {
            let lightTint = BrandPalette.blend(pair.light, alpha: alpha, over: lightWindow)
            let darkTint = BrandPalette.blend(pair.dark, alpha: alpha, over: darkWindow)
            #expect(BrandPalette.contrast(pair.light, lightTint) >= 3, "status.\(pair.name) light banner")
            #expect(BrandPalette.contrast(pair.dark, darkTint) >= 3, "status.\(pair.name) dark banner")
        }
    }

    /// The neutral banner has no brand token: its glyph is `secondaryLabelColor` (itself translucent) on a tint of
    /// the same colour. The glyph, composited over that tint, keeps 3:1 in both appearances.
    @MainActor
    @Test func theNeutralGlyphHasThreeToOneOnItsBannerTint() throws {
        let windows: [(NSAppearance.Name, UInt32)] = [(.aqua, 0xECECEC), (.darkAqua, 0x323232)]
        for (name, window) in windows {
            let appearance = try #require(NSAppearance(named: name))
            var rgb: UInt32 = 0
            var alpha = 0.0
            appearance.performAsCurrentDrawingAppearance {
                guard let colour = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) else { return }
                func byte(_ value: CGFloat) -> UInt32 { UInt32((max(0, min(1, value)) * 255).rounded()) }
                rgb = byte(colour.redComponent) << 16 | byte(colour.greenComponent) << 8 | byte(colour.blueComponent)
                alpha = Double(colour.alphaComponent)
            }
            #expect(alpha > 0, "\(name.rawValue): secondaryLabelColor resolves")
            let tint = BrandPalette.blend(rgb, alpha: alpha * LintelBrand.statusTintAlpha, over: window)
            let glyph = BrandPalette.blend(rgb, alpha: alpha, over: tint)
            #expect(BrandPalette.contrast(glyph, tint) >= 3, "status.neutral \(name.rawValue) banner")
        }
    }
}

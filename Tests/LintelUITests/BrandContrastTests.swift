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

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

/// The main window's Settings sidebar (prototype `.si.on`): the selected row is `windowSelectionTint` over the
/// sidebar fill (`--side`), its label and icon `accentText`.
@Suite struct SettingsSidebarContrastTests {
    @Test func theSelectedRowLabelIsReadableInBothAppearances() {
        let cases: [(String, UInt32, UInt32, UInt32, Double)] = [
            (
                "light", BrandPalette.sidebarLight, BrandPalette.accentLight, BrandPalette.accentTextLight,
                BrandPalette.windowSelectionTintAlpha.light
            ),
            (
                "dark", BrandPalette.sidebarDark, BrandPalette.accentDark, BrandPalette.accentTextDark,
                BrandPalette.windowSelectionTintAlpha.dark
            ),
        ]
        for (name, sidebar, accent, text, alpha) in cases {
            let row = BrandPalette.blend(accent, alpha: alpha, over: sidebar)
            #expect(BrandPalette.contrast(text, row) >= 4.5, "\(name) label")
            // The selected row's icon and the accent as a graphic.
            #expect(BrandPalette.contrast(accent, row) >= 3, "\(name) icon")
        }
    }

    /// Unselected labels are `ink` and group labels, icons and "Off" are `secondaryText` on the sidebar fill.
    @Test func theSidebarTextIsReadable() {
        #expect(BrandPalette.contrast(BrandPalette.inkLight, BrandPalette.sidebarLight) >= 7)
        #expect(BrandPalette.contrast(BrandPalette.inkDark, BrandPalette.sidebarDark) >= 7)
        #expect(BrandPalette.contrast(BrandPalette.secondaryTextLight, BrandPalette.sidebarLight) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.secondaryTextDark, BrandPalette.sidebarDark) >= 4.5)
    }
}

@Suite struct StatusBannerContrastTests {
    // The banner is the prototype's `.bn`: `--card` over `--win`. The grouped form's sections (the system fill
    // over `--win`, captured) are listed too, since the status colours appear there as well.
    private let lightCards: [UInt32] = [BrandPalette.cardLight, BrandPalette.windowLight, 0xF2F1ED]
    private let darkCards: [UInt32] = [BrandPalette.cardDark, BrandPalette.windowDark, 0x2F2B25]
    private let pairs: [(name: String, light: UInt32, dark: UInt32)] = [
        ("ok", BrandPalette.statusOkLight, BrandPalette.statusOkDark),
        ("attention", BrandPalette.statusAttentionLight, BrandPalette.statusAttentionDark),
        ("error", BrandPalette.statusErrorLight, BrandPalette.statusErrorDark),
    ]

    /// The filled status circle is a graphic: 3:1 against the card it sits on.
    @Test func eachStatusCircleHasThreeToOneOnTheBannerCard() {
        for pair in pairs {
            for card in lightCards {
                #expect(BrandPalette.contrast(pair.light, card) >= 3, "status.\(pair.name) light")
            }
            for card in darkCards {
                #expect(BrandPalette.contrast(pair.dark, card) >= 3, "status.\(pair.name) dark")
            }
        }
    }

    /// The glyph cut into the circle (`onStatus`) keeps 3:1 against every status fill.
    @Test func theGlyphHasThreeToOneOnEachStatusCircle() {
        for pair in pairs {
            #expect(BrandPalette.contrast(BrandPalette.onStatusLight, pair.light) >= 3, "status.\(pair.name) light")
            #expect(BrandPalette.contrast(BrandPalette.onStatusDark, pair.dark) >= 3, "status.\(pair.name) dark")
        }
    }

    /// The neutral circle is `secondaryText` (prototype `.bn .g`, `--sec`) with the `onStatus` glyph: 3:1 for
    /// the circle on the card and for the glyph on the circle, in both appearances.
    @Test func theNeutralCircleAndItsGlyphHaveThreeToOne() {
        #expect(BrandPalette.contrast(BrandPalette.secondaryTextLight, BrandPalette.cardLight) >= 3)
        #expect(BrandPalette.contrast(BrandPalette.secondaryTextDark, BrandPalette.cardDark) >= 3)
        #expect(BrandPalette.contrast(BrandPalette.onStatusLight, BrandPalette.secondaryTextLight) >= 3)
        #expect(BrandPalette.contrast(BrandPalette.onStatusDark, BrandPalette.secondaryTextDark) >= 3)
    }

    /// The banner's detail line is `secondaryText` on `--card`.
    @Test func theDetailTextIsReadableOnTheCard() {
        #expect(BrandPalette.contrast(BrandPalette.secondaryTextLight, BrandPalette.cardLight) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.secondaryTextDark, BrandPalette.cardDark) >= 4.5)
    }

    @Test func theGlyphTokensKeepTheirValues() {
        #expect(BrandPalette.onStatusLight == 0xFFFFFF && BrandPalette.onStatusDark == 0x161310)
    }
}

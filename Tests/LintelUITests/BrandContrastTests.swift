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

/// The main window's Settings sidebar (prototype `.si.on`): the selected row is `selectionTint` over the window
/// fill, its label and icon `accentText`.
@Suite struct SettingsSidebarContrastTests {
    /// The sidebar sits on the window fill: `windowBackgroundColor` as the system resolves it, and the fill the
    /// QA captures measured (macOS 26 tints the dark one with the desktop picture).
    @MainActor
    @Test func theSelectedRowLabelIsReadableInBothAppearances() throws {
        let cases: [(NSAppearance.Name, [UInt32], UInt32, UInt32, Double)] = [
            (
                .aqua, [0xFFFFFF], BrandPalette.accentLight, BrandPalette.accentTextLight,
                LintelBrand.selectionTintAlpha.light
            ),
            (
                .darkAqua, [0x1E222D], BrandPalette.accentDark, BrandPalette.accentTextDark,
                LintelBrand.selectionTintAlpha.dark
            ),
        ]
        for (name, captured, accent, text, alpha) in cases {
            let appearance = try #require(NSAppearance(named: name))
            var window: UInt32 = 0
            appearance.performAsCurrentDrawingAppearance {
                guard let colour = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) else { return }
                func byte(_ value: CGFloat) -> UInt32 { UInt32((max(0, min(1, value)) * 255).rounded()) }
                window = byte(colour.redComponent) << 16 | byte(colour.greenComponent) << 8 | byte(colour.blueComponent)
            }
            for background in captured + [window] {
                let row = BrandPalette.blend(accent, alpha: alpha, over: background)
                #expect(BrandPalette.contrast(text, row) >= 4.5, "\(name.rawValue) on \(String(background, radix: 16))")
                // The selected row's icon and the accent as a graphic.
                #expect(BrandPalette.contrast(accent, row) >= 3, "\(name.rawValue) icon")
            }
        }
    }
}

@Suite struct StatusBannerContrastTests {
    // The banner is a card like the grouped form's sections (`quaternarySystemFill` over the window): the
    // captured fills of the main window, light and dark, plus the classic window fills.
    private let lightCards: [UInt32] = [0xF8F8F8, 0xFFFFFF, 0xECECEC]
    private let darkCards: [UInt32] = [0x242833, 0x1E222D, 0x323232]
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

    /// The neutral circle has no brand token: it is `secondaryLabelColor` (itself translucent) over the card,
    /// with the `onStatus` glyph. Both keep 3:1 in both appearances.
    @MainActor
    @Test func theNeutralCircleAndItsGlyphHaveThreeToOne() throws {
        let cases: [(NSAppearance.Name, UInt32, UInt32)] = [
            (.aqua, 0xF8F8F8, BrandPalette.onStatusLight), (.darkAqua, 0x242833, BrandPalette.onStatusDark),
        ]
        for (name, card, glyph) in cases {
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
            let circle = BrandPalette.blend(rgb, alpha: alpha, over: card)
            #expect(BrandPalette.contrast(circle, card) >= 3, "status.neutral \(name.rawValue) circle")
            #expect(BrandPalette.contrast(glyph, circle) >= 3, "status.neutral \(name.rawValue) glyph")
        }
    }

    @Test func theGlyphTokensKeepTheirValues() {
        #expect(BrandPalette.onStatusLight == 0xFFFFFF && BrandPalette.onStatusDark == 0x161310)
    }
}

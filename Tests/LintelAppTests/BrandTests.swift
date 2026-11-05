import AppKit
import SwiftUI
import Testing

@testable import LintelApp

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
}

@MainActor
@Suite struct LintelMarkTests {
    /// Alpha (0...1) of the ring rendered at 256 x 256 at a point on the 256-point grid.
    private func alpha(small: Bool = false, at point: CGPoint) throws -> CGFloat {
        let renderer = ImageRenderer(content: LintelMarkRing(small: small).fill(.black).frame(width: 256, height: 256))
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.colorAt(x: Int(point.x), y: Int(point.y))).alphaComponent
    }

    /// A point at `radius` from the centre, `degrees` clockwise on screen from the x axis.
    private func point(radius: CGFloat, degrees: Double) -> CGPoint {
        CGPoint(
            x: 128 + radius * CGFloat(cos(degrees * .pi / 180)),
            y: 128 + radius * CGFloat(sin(degrees * .pi / 180)))
    }

    @Test func theRingHasItsCutOnTheUpperLeft() throws {
        let middleOfRing = (LintelMarkRing.outerRadius + LintelMarkRing.innerRadius) / 2
        // The middle of the cut is empty ...
        #expect(try alpha(at: point(radius: middleOfRing, degrees: -135)) < 0.01)
        // ... and the ring is solid everywhere else around it.
        for degrees in [-90.0, -45, 0, 45, 90, 135, 180] {
            #expect(try alpha(at: point(radius: middleOfRing, degrees: degrees)) > 0.99, "at \(degrees) degrees")
        }
    }

    @Test func theRingLeavesTheCentreFreeForTheCore() throws {
        #expect(try alpha(at: CGPoint(x: 128, y: 128)) < 0.01)
        #expect(try alpha(at: point(radius: LintelMarkRing.innerRadius - 4, degrees: 45)) < 0.01)
        #expect(try alpha(at: point(radius: LintelMarkRing.outerRadius + 4, degrees: 45)) < 0.01)
    }

    @Test func theSmallCutHasAThinnerRing() throws {
        // At 62 from the centre the regular ring is solid (inner radius 66 is farther out); the small one,
        // whose inner radius is 60, is solid there too, while at 63 only the small one is.
        #expect(try alpha(small: true, at: point(radius: 63, degrees: 45)) > 0.99)
        #expect(try alpha(small: false, at: point(radius: 63, degrees: 45)) < 0.01)
    }

    @Test func theMenuBarGlyphIsATemplateImage() {
        let image = LintelMark.menuBarImage()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }
}

@Suite struct BrandAssetCatalogTests {
    /// `Resources/Assets.xcassets`, found from this file: the catalog is compiled by `scripts/make-app.sh`, so
    /// these values must never drift from `BrandPalette`.
    private func hexes(ofColorSet name: String) throws -> (light: UInt32, dark: UInt32) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Assets.xcassets/\(name).colorset/Contents.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let colors = try #require(json["colors"] as? [[String: Any]])
        func hex(_ entry: [String: Any]) throws -> UInt32 {
            let color = try #require(entry["color"] as? [String: Any])
            let parts = try #require(color["components"] as? [String: String])
            func channel(_ key: String) throws -> UInt32 {
                let text = try #require(parts[key])
                return try #require(UInt32(text.dropFirst(2), radix: 16))
            }
            return try channel("red") << 16 | channel("green") << 8 | channel("blue")
        }
        let light = try #require(colors.first { $0["appearances"] == nil })
        let dark = try #require(colors.first { $0["appearances"] != nil })
        return (try hex(light), try hex(dark))
    }

    @Test func accentColorMatchesThePalette() throws {
        let accent = try hexes(ofColorSet: "AccentColor")
        #expect(accent.light == BrandPalette.accentLight)
        #expect(accent.dark == BrandPalette.accentDark)
    }

    @Test func accentTextMatchesThePalette() throws {
        let text = try hexes(ofColorSet: "AccentText")
        #expect(text.light == BrandPalette.accentTextLight)
        #expect(text.dark == BrandPalette.accentTextDark)
    }
}

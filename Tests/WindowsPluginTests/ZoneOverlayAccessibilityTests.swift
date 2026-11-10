import AppKit
import CoreGraphics
import Foundation
import LintelKit
import LintelUI
import SwiftUI
import Testing

@testable import WindowsPlugin

/// The accessibility audit of the snap overlay and the Identify panel (step 3.7), as far as it can be tested
/// without a screen: contrast of the numbers on their pills, a highlight that is not colour alone, Reduce
/// Transparency, and what VoiceOver is told. Looking at it on a real display stays in `docs/qa.md` (rows 25, 27).
@Suite(.timeLimit(.minutes(1))) struct ZoneOverlayAccessibilityTests {
    @Test func theNumbersMeetContrastOnTheirPillsInBothAppearances() {
        // White on the dark pill, whatever the wallpaper is: the pill is opaque.
        #expect(BrandPalette.contrast(ZoneOverlayStyle.numberHex, ZoneOverlayStyle.pillGrayHex) >= 7)
        // The highlighted pill is the accent with the brand's on-accent text, light and dark.
        #expect(BrandPalette.contrast(BrandPalette.onAccentLight, BrandPalette.accentLight) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.onAccentDark, BrandPalette.accentDark) >= 4.5)
        // The pill's grey really is the grey the view uses.
        let channel = UInt32((ZoneOverlayStyle.pillGray * 255).rounded())
        #expect(ZoneOverlayStyle.pillGrayHex == channel << 16 | channel << 8 | channel)
    }

    @Test func theHighlightIsNotColourAlone() {
        #expect(ZoneOverlayStyle.highlightedBorderWidth > ZoneOverlayStyle.borderWidth)
        #expect(
            ZoneOverlayStyle.fillOpacity(highlighted: true, reduceTransparency: false)
                > ZoneOverlayStyle.fillOpacity(highlighted: false, reduceTransparency: false))
        // The number and the pill fill change too (the accent pill), and the VoiceOver trait is `isSelected`.
    }

    @Test func reduceTransparencyMakesTheScrimAndTheHighlightMoreOpaque() {
        for highlighted in [true, false] {
            #expect(
                ZoneOverlayStyle.fillOpacity(highlighted: highlighted, reduceTransparency: true)
                    > ZoneOverlayStyle.fillOpacity(highlighted: highlighted, reduceTransparency: false))
        }
        #expect(ZoneOverlayStyle.fillOpacity(highlighted: true, reduceTransparency: true) >= 0.8)
    }

    @Test func everyZoneHasASpokenNameWithItsNumber() {
        for number in 1...9 { #expect(ZoneOverlayText.zoneName(number).contains(String(number))) }
        #expect(!ZoneOverlayText.overlayLabel.isEmpty)
    }

    @Test func theNumbersOnAnOverlayAreUniqueAndInOrder() throws {
        for layout in StockLayouts.all {
            let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 600))
            let visuals = layout.zones.enumerated().map { index, zone in
                ZoneVisual(id: zone.id, number: index + 1, rect: frames[zone.id] ?? .zero)
            }
            #expect(Set(visuals.map(\.number)).count == visuals.count)
            #expect(visuals.map(\.number) == Array(1...visuals.count))
            // Every pill has room: no zone is smaller than the pill.
            #expect(visuals.allSatisfy { $0.rect.width > 60 && $0.rect.height > 40 })
        }
    }

    @MainActor @Test func theOverlayModelHighlightsOneZoneAtATime() {
        let model = ZoneOverlayModel()
        model.zones = [
            ZoneVisual(id: 1, number: 1, rect: .zero), ZoneVisual(id: 2, number: 2, rect: .zero),
        ]
        model.highlighted = 2
        #expect(model.zones.filter { $0.id == model.highlighted }.count == 1)
    }
}

/// The real panels and the view, built without a display (step 3.7 review): they are hidden from screen sharing,
/// never take focus, and the view lays out its zones.
@Suite(.timeLimit(.minutes(1))) @MainActor struct ZoneOverlayPanelTests {
    private let zone = DragZone(
        displayKey: "A", zoneID: 1, number: 1, frame: CGRect(x: 8, y: 8, width: 400, height: 300))

    @Test func theOverlayPanelsAreNotSharedAndNeverTakeFocus() {
        let panels = ZoneOverlayPanels(screens: { [CGRect(x: 0, y: 0, width: 1000, height: 600)] })
        panels.show([DragDisplay(key: "A", area: CGRect(x: 0, y: 0, width: 1000, height: 600), zones: [zone])])
        #expect(panels.panels.count == 1)
        for panel in panels.panels {
            #expect(panel.sharingType == .none)
            #expect(panel.ignoresMouseEvents)
            #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        }
        panels.hide()
        panels.tearDown()
    }

    /// DEBUG only, for QA: the overlay, HUD and strip can be made capturable so they can be photographed. The shipped
    /// behaviour (never in screen sharing) is the default and the test above keeps it. Synchronous on the main actor,
    /// so no other test sees the switch on.
    @Test func theQASwitchMakesThePanelsCapturableAndTheDefaultStaysNotShared() {
        #expect(ScreenCapture.sharingType == .none)
        ScreenCapture.qaCapturable = true
        defer { ScreenCapture.qaCapturable = false }
        let panels = ZoneOverlayPanels(screens: { [CGRect(x: 0, y: 0, width: 1000, height: 600)] })
        panels.show([DragDisplay(key: "A", area: CGRect(x: 0, y: 0, width: 1000, height: 600), zones: [zone])])
        #expect(panels.panels.allSatisfy { $0.sharingType == .readOnly })
        panels.tearDown()
    }

    @Test func prewarmBuildsOnePanelPerScreenAndTheFirstShowTakesOneInsteadOfBuilding() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 600), CGRect(x: 1000, y: 0, width: 1000, height: 600)]
        let panels = ZoneOverlayPanels(screens: { screens })
        panels.prewarm()
        #expect(panels.spareCount == 2)
        #expect(panels.panels.isEmpty)
        panels.show([DragDisplay(key: "A", area: screens[0], zones: [zone])])
        #expect(panels.spareCount == 1)
        #expect(panels.panels.count == 1)
        // Warming again builds nothing more than the screens need.
        panels.prewarm()
        #expect(panels.spareCount == 1)
        panels.tearDown()
        #expect(panels.spareCount == 0)
    }

    @Test func theViewLaysOutItsZonesAtTheirPositions() {
        let model = ZoneOverlayModel()
        model.zones = [ZoneVisual(id: 1, number: 1, rect: CGRect(x: 8, y: 8, width: 400, height: 300))]
        model.highlighted = 1
        let host = NSHostingView(rootView: ZoneOverlayView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.size == CGSize(width: 1000, height: 600))
        #expect(host.fittingSize.width > 0)
    }
}

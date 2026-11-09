import AppKit
import LintelUI
import Observation
import SwiftUI

/// One zone as the overlay draws it: its frame in the top-left space of the panel and its number.
struct ZoneVisual: Identifiable, Equatable {
    var id: Int
    var number: Int
    var rect: CGRect
}

/// What one overlay panel draws. Pure values, so the numbers, the highlight and the spoken text are tested
/// without a screen.
@MainActor @Observable
final class ZoneOverlayModel {
    var zones: [ZoneVisual] = []
    var highlighted: Int?
    /// Draws a name on every zone instead of the number only (*Identify*).
    var caption: String?
}

enum ZoneOverlayText {
    /// What VoiceOver hears for a zone (the spec's "Zone 2"), and the label of the pill.
    static func zoneName(_ number: Int) -> String {
        String(localized: "Zone \(number)", comment: "Snap overlay: the name of a zone, spoken when it is highlighted")
    }

    static let overlayLabel = String(
        localized: "Zones. Release to snap the window.",
        comment: "Snap overlay: what VoiceOver hears for the overlay while a window is dragged")

    static let hint = String(
        localized: "Hold ⇧ while dragging to snap",
        comment: "Window HUD: shown once, the first time a Zones layout is active")
}

/// The overlay of one display (mockup 02): the zones with their numbers on opaque pills (so they meet contrast on
/// any wallpaper and in both appearances) and the zone under the cursor highlighted with the accent. It never
/// takes a click: the dragged window is under the cursor.
struct ZoneOverlayView: View {
    var model: ZoneOverlayModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.zones) { zone in
                let highlighted = model.highlighted == zone.id
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill(highlighted: highlighted))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            highlighted ? LintelBrand.accent : Color.white.opacity(contrast == .increased ? 1 : 0.75),
                            lineWidth: highlighted ? 3 : 2)
                    VStack(spacing: 6) {
                        Text(verbatim: "\(zone.number)")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(highlighted ? LintelBrand.onAccent : Color.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(highlighted ? LintelBrand.accent : Color(white: 0.09)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        if let caption = model.caption {
                            Text(verbatim: caption)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(white: 0.09)))
                        }
                    }
                }
                .frame(width: zone.rect.width, height: zone.rect.height)
                .offset(x: zone.rect.minX, y: zone.rect.minY)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ZoneOverlayText.zoneName(zone.number))
                .accessibilityAddTraits(highlighted ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ZoneOverlayText.overlayLabel)
    }

    private func fill(highlighted: Bool) -> Color {
        if highlighted { return LintelBrand.accent.opacity(reduceTransparency ? 0.85 : 0.45) }
        return Color.black.opacity(reduceTransparency ? 0.7 : 0.3)
    }
}

/// A panel that never becomes key or main and never takes a click.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The real overlay: one borderless, non-activating panel per display, created on first use and reused (so it
/// appears within the 50 ms budget), over the whole screen. A panel that is not needed is ordered out, never
/// destroyed while the plugin runs; `tearDown()` releases them all.
@MainActor
final class ZoneOverlayPanels: ZoneOverlayPresenting {
    private struct Entry {
        let panel: NSPanel
        let model: ZoneOverlayModel
    }

    private var entries: [String: Entry] = [:]
    private var highlighted: DragZone?
    private var announced: Int?
    private let screens: () -> [CGRect]

    init(screens: @escaping () -> [CGRect] = { NSScreen.screens.map(\.frame) }) {
        self.screens = screens
    }

    func show(_ displays: [DragDisplay]) {
        let frames = screens()
        let mainHeight = frames.first?.height ?? 0
        var shown = Set<String>()
        for display in displays {
            guard let index = ScreenSpace.screenIndex(forAX: display.area, screenFrames: frames, mainHeight: mainHeight)
            else { continue }
            let frame = frames[index]
            let entry = entries[display.key] ?? makeEntry(for: display.key)
            entries[display.key] = entry
            entry.model.zones = display.zones.map {
                ZoneVisual(
                    id: $0.zoneID, number: $0.number,
                    rect: ScreenSpace.localRect($0.frame, screenFrame: frame, mainHeight: mainHeight))
            }
            entry.model.caption = nil
            entry.panel.setFrame(frame, display: false)
            entry.panel.orderFrontRegardless()
            shown.insert(display.key)
        }
        for (key, entry) in entries where !shown.contains(key) { entry.panel.orderOut(nil) }
        applyHighlight()
    }

    func highlight(_ zone: DragZone?) {
        highlighted = zone
        applyHighlight()
        guard let zone, zone.number != announced else {
            if zone == nil { announced = nil }
            return
        }
        announced = zone.number
        guard let panel = entries[zone.displayKey]?.panel else { return }
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: ZoneOverlayText.zoneName(zone.number),
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    func hide() {
        for entry in entries.values { entry.panel.orderOut(nil) }
        highlighted = nil
        announced = nil
        applyHighlight()
    }

    /// Releases every panel (the plugin was switched off).
    func tearDown() {
        for entry in entries.values {
            entry.panel.orderOut(nil)
            entry.panel.close()
        }
        entries = [:]
    }

    private func applyHighlight() {
        for (key, entry) in entries {
            entry.model.highlighted = highlighted?.displayKey == key ? highlighted?.zoneID : nil
        }
    }

    private func makeEntry(for key: String) -> Entry {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let model = ZoneOverlayModel()
        panel.contentView = NSHostingView(rootView: ZoneOverlayView(model: model))
        return Entry(panel: panel, model: model)
    }
}

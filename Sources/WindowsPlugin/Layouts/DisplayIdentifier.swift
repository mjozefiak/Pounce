import AppKit
import LintelUI
import SwiftUI

/// *Identify* (Layouts window): a large number and the display's name on that display for two seconds, so the
/// matrix columns can be matched to the screens. A borderless, non-activating panel that takes no click and no
/// focus; it announces itself to VoiceOver too.
@MainActor
final class DisplayIdentifier {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let screens: () -> [CGRect]
    private let duration: Duration

    init(screens: @escaping () -> [CGRect] = { NSScreen.screens.map(\.frame) }, duration: Duration = .seconds(2)) {
        self.screens = screens
        self.duration = duration
    }

    func show(_ display: MatrixDisplay) {
        let frames = screens()
        let mainHeight = frames.first?.height ?? 0
        guard let index = ScreenSpace.screenIndex(forAX: display.area, screenFrames: frames, mainHeight: mainHeight)
        else { return }
        hideTask?.cancel()
        panel?.close()
        let panel = makePanel(for: display)
        self.panel = panel
        panel.setFrame(frames[index], display: false)
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: display.title,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        let duration = duration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.panel?.close()
            self?.panel = nil
        }
    }

    func tearDown() {
        hideTask?.cancel()
        panel?.close()
        panel = nil
    }

    private func makePanel(for display: MatrixDisplay) -> NSPanel {
        let panel = IdentifyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: IdentifyView(number: display.number, title: display.title))
        return panel
    }
}

private final class IdentifyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The number on an opaque pill, centred on the display.
struct IdentifyView: View {
    var number: Int
    var title: String

    var body: some View {
        VStack(spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(LintelBrand.onAccent)
                .frame(minWidth: 150)
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
                .background(Capsule().fill(LintelBrand.accent))
            Text(verbatim: title)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(white: 0.09)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: title))
    }
}

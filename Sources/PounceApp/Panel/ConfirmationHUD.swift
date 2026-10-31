import AppKit
import SwiftUI

/// A brief, non-activating message bubble ("Copied") shown after the panel closed, for example when
/// pasting falls back to copying. It never takes focus and ignores the mouse.
final class ConfirmationHUD {
    static let duration: Duration = .milliseconds(1400)

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private(set) var message: String?

    func show(_ message: String, near frame: NSRect) {
        self.message = message
        let panel = panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: ConfirmationView(message: message))
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        glass.contentView = hosting
        panel.contentView = glass
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        let anchor = frame.isEmpty ? (screen?.visibleFrame ?? .zero) : frame
        panel.setFrame(
            NSRect(
                x: (anchor.midX - size.width / 2).rounded(), y: (anchor.maxY - 56 - size.height).rounded(),
                width: size.width, height: size.height),
            display: true
        )
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        message = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

struct ConfirmationView: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "checkmark.circle")
                .symbolRenderingMode(.hierarchical)
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

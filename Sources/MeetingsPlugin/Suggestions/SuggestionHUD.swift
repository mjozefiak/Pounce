import AppKit
import Observation
import SwiftUI

/// The state the suggestion HUD's view reads.
@MainActor @Observable
final class SuggestionHUDModel {
    var prompt = SuggestionPrompt.meeting(bundleID: "", appName: "")
    var reducesMotion = false
    @ObservationIgnored var onAction: (SuggestionAction) -> Void = { _ in }
}

/// The meeting suggestion: a pill with a line of text and clickable buttons. A non-activating panel, so the
/// app the user is meeting in keeps the focus. It differs from the recording HUD in two ways the spec asks
/// for: it is **not** shown in screen sharing (`sharingType = .none`; the people on the call must not see
/// "looks like a meeting in …"), and it claims **no keys**: no global Return or Escape, no key monitor, no
/// shortcut on its buttons, so it cannot take a keystroke from the app the user is typing in. Disappearing
/// after 15 s is the detector's job (it owns the clock).
@MainActor
final class SuggestionHUDPanel: SuggestionPresenter {
    private static let width: CGFloat = 440
    private static let height: CGFloat = 78
    private static let margin: CGFloat = 8

    private let model = SuggestionHUDModel()
    private var panel: NSPanel?
    private let reducesMotion: () -> Bool

    init(
        onAction: @escaping (SuggestionAction) -> Void,
        reducesMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.reducesMotion = reducesMotion
        model.onAction = onAction
    }

    func show(_ prompt: SuggestionPrompt) {
        model.reducesMotion = reducesMotion()
        model.prompt = prompt
        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { place(panel) }
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: prompt.announcement,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        // Hidden from screen sharing and recording: only the person at the Mac sees it.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: SuggestionHUDView(model: model))
        return panel
    }

    /// Top centre of the screen with the mouse, under the menu bar (where the recording HUD sits too).
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setContentSize(NSSize(width: Self.width, height: Self.height))
        panel.setFrameOrigin(
            NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - Self.height - Self.margin))
    }
}

struct SuggestionHUDView: View {
    let model: SuggestionHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let prompt = model.prompt
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: prompt.symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(prompt.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                ForEach(Array(prompt.actions.enumerated()), id: \.offset) { index, action in
                    button(action, title: prompt.title(for: action), primary: index == 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 30)
        }
        .padding(.horizontal, 14)
        .frame(width: 440, height: 78, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.6), lineWidth: 1)
            }
        }
        .transaction { if reduceMotion || model.reducesMotion { $0.animation = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt.accessibilityLabel)
    }

    @ViewBuilder
    private func button(_ action: SuggestionAction, title: String, primary: Bool) -> some View {
        if primary {
            Button(title) { model.onAction(action) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(title) { model.onAction(action) }
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
        }
    }
}

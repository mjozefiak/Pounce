import AppKit
import Observation
import SwiftUI

/// Shows the HUD. The window in the app, a recording fake in tests.
@MainActor
protocol HUDPresenter: AnyObject {
    func show(_ state: HUDState)
    func hide()
}

/// Decides which states VoiceOver hears. The HUD is shown again for every level update while recording, so
/// an announcement is made only when its text differs from the last one spoken.
struct AnnouncementGate {
    private var last: String?

    mutating func announce(_ state: HUDState) -> String? {
        guard let text = state.announcement, text != last else { return nil }
        last = text
        return text
    }

    mutating func reset() {
        last = nil
    }
}

/// The state the HUD's view reads.
@MainActor @Observable
final class HUDModel {
    var state = HUDState.finishing
    /// When the recording began, for the running time.
    var recordingStartedAt: Date?
    var reducesMotion = false
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onOpenSettings: () -> Void = {}
}

/// A small pill at the bottom of the screen with the mouse cursor. A non-activating panel: it never takes
/// the focus from the app the user is dictating into, and it ignores the mouse apart from its buttons.
@MainActor
final class DictationHUDPanel: HUDPresenter {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var announcements = AnnouncementGate()
    private let reducesMotion: () -> Bool

    init(
        onCancel: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
        reducesMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.reducesMotion = reducesMotion
        model.onCancel = onCancel
        model.onOpenSettings = onOpenSettings
    }

    func show(_ state: HUDState) {
        hideTask?.cancel()
        hideTask = nil
        let wasRecording = model.state.offersCancel
        model.reducesMotion = reducesMotion()
        if state.offersCancel, !wasRecording || model.recordingStartedAt == nil {
            model.recordingStartedAt = Date()
        }
        model.state = state
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        if let announcement = announcements.announce(state) {
            announce(announcement, from: panel)
        }
        if let delay = state.hidesAfter {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        model.recordingStartedAt = nil
        announcements.reset()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: DictationHUDView(model: model))
        return panel
    }

    /// Bottom centre of the screen the mouse is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
    }

    private func announce(_ text: String, from panel: NSPanel) {
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: text,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }
}

struct DictationHUDView: View {
    let model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let state = model.state
        HStack(spacing: 10) {
            icon(for: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.system(.callout, weight: .medium))
                    .lineLimit(1)
                if let detail = state.detail, !state.offersSettings {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if case .recording(let recording) = state {
                LevelBars(level: recording.level, animated: !(reduceMotion || model.reducesMotion))
                if let started = model.recordingStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.format(context.date.timeIntervalSince(started)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if state.offersSettings {
                Button(state.detail ?? "") { model.onOpenSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if state.offersCancel {
                Button {
                    model.onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    String(localized: "Cancel dictation", comment: "Accessibility label of the HUD's ✕"))
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 280, height: 56)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(contrast == .increased ? 0.6 : 0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.accessibilityLabel)
    }

    @ViewBuilder
    private func icon(for state: HUDState) -> some View {
        if case .recording(let recording) = state, !recording.loadingModel {
            Circle().fill(.red).frame(width: 10, height: 10)
                .accessibilityHidden(true)
        } else if case .finishing = state {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: state.symbolName).frame(width: 16).accessibilityHidden(true)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A few bars that follow the microphone level; flat when Reduce Motion is on.
private struct LevelBars: View {
    let level: Float
    let animated: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index) / 5
                Capsule()
                    .fill(level > threshold ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: 3, height: 6 + CGFloat(index) * 3)
            }
        }
        .animation(animated ? .easeOut(duration: 0.08) : nil, value: level)
        .accessibilityHidden(true)
    }
}

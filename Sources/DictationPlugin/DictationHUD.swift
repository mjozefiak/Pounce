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
                .frame(width: 20, height: 20)
            Text(state.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if case .recording(let recording) = state {
                Spacer(minLength: 4)
                LevelBars(level: recording.level, animated: !(reduceMotion || model.reducesMotion))
                if let started = model.recordingStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.format(context.date.timeIntervalSince(started)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
            if state.offersSettings {
                Button(state.detail ?? "") { model.onOpenSettings() }
                    .buttonStyle(.link)
                    // The brand's text-grade accent (4.5:1 on the glass) from the app's asset catalog; the system
                    // accent when the catalog is missing (`swift run`, tests).
                    .foregroundStyle(Color(nsColor: NSColor(named: "AccentText") ?? .controlAccentColor))
                    .font(.system(size: 12, weight: .medium))
            }
            if state.offersCancel {
                Button {
                    model.onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(localized: "Cancel dictation", comment: "Accessibility label of the HUD's ✕"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(width: 248, height: 40)
        .glassEffect(.regular, in: .capsule)
        .overlay {
            if contrast == .increased { Capsule().strokeBorder(.primary.opacity(0.6), lineWidth: 1) }
        }
        .frame(width: 280, height: 56)
        .animation(reduceMotion || model.reducesMotion ? nil : .smooth(duration: 0.2), value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.accessibilityLabel)
    }

    @ViewBuilder
    private func icon(for state: HUDState) -> some View {
        switch state {
        case .recording(let recording) where !recording.loadingModel:
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.red)
                .font(.title3)
                .symbolEffect(.pulse, isActive: !(reduceMotion || model.reducesMotion))
                .accessibilityHidden(true)
        case .finishing, .recording:
            BrandCaret(animated: !(reduceMotion || model.reducesMotion))
                .accessibilityHidden(true)
        case .pasted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.title3).accessibilityHidden(true)
        case .pastedUnformatted, .copied, .allowMicrophone:
            Image(systemName: state.symbolName).foregroundStyle(.orange)
                .font(.title3).accessibilityHidden(true)
        case .problem:
            Image(systemName: state.symbolName).foregroundStyle(.red)
                .font(.title3).accessibilityHidden(true)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The "working" indicator: the accent caret. It blinks, or stays solid when Reduce Motion is on.
private struct BrandCaret: View {
    let animated: Bool
    @State private var lit = true

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3, height: 16)
            .opacity(lit ? 1 : 0.25)
            .task(id: animated) {
                lit = true
                guard animated else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(550))
                    lit.toggle()
                }
            }
    }
}

/// Bars that follow the microphone level, tallest in the middle; flat when Reduce Motion is on.
private struct LevelBars: View {
    let level: Float
    let animated: Bool
    private static let profile: [CGFloat] = [0.45, 0.7, 1, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.profile.count, id: \.self) { index in
                let height = 4 + 14 * CGFloat(min(1, max(0, level))) * Self.profile[index]
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 18)
        .animation(animated ? .easeOut(duration: 0.08) : nil, value: level)
        .accessibilityHidden(true)
    }
}

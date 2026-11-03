import AppKit
import Observation
import SwiftUI

/// Shows the meeting HUD. The window in the app, a recording fake in tests. Internal to the plugin: only
/// `MeetingsPlugin` uses it (spec: Architecture).
@MainActor
protocol HUDPresenter: AnyObject {
    func show(_ state: MeetingHUDState)
    func hide()
}

/// Decides which states VoiceOver hears. The HUD is shown again for every level and second while recording,
/// so each announcement is made once per HUD session (until `reset()`).
struct MeetingAnnouncementGate {
    private var spoken: Set<String> = []

    mutating func announce(_ state: MeetingHUDState) -> String? {
        guard let text = state.announcement, spoken.insert(text).inserted else { return nil }
        return text
    }

    mutating func reset() {
        spoken = []
    }
}

/// The state the HUD's view reads.
@MainActor @Observable
final class MeetingHUDModel {
    var state = MeetingHUDState.finishing
    var reducesMotion = false
    @ObservationIgnored var onAction: (MeetingHUDState.Action) -> Void = { _ in }
}

/// A pill at the top of the screen with the mouse cursor: a non-activating panel that never takes the focus
/// from the app the user is meeting in, and ignores the mouse apart from its buttons. It looks like the
/// dictation HUD but is its own implementation. It is visible in screen sharing on purpose: the people on the
/// call can see that the meeting is being recorded.
@MainActor
final class MeetingHUDPanel: HUDPresenter {
    private static let width: CGFloat = 400
    private static let singleLineHeight: CGFloat = 44
    private static let twoLineHeight: CGFloat = 68
    private static let margin: CGFloat = 8

    private let model = MeetingHUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var announcements = MeetingAnnouncementGate()
    private let reducesMotion: () -> Bool
    private var shownState: MeetingHUDState?

    init(
        onAction: @escaping (MeetingHUDState.Action) -> Void,
        reducesMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.reducesMotion = reducesMotion
        model.onAction = onAction
    }

    func show(_ state: MeetingHUDState) {
        // A different screen (or a different problem) restarts the hide timer; the recording refreshes every
        // second and must not.
        let changedKind = shownState.map { Self.screen($0) != Self.screen(state) } ?? true
        shownState = state
        model.reducesMotion = reducesMotion()
        model.state = state
        let panel = panel ?? makePanel()
        self.panel = panel
        layout(panel, for: state)
        panel.orderFrontRegardless()
        if let announcement = announcements.announce(state) {
            announce(announcement, from: panel)
        }
        if changedKind || state.hidesAfter == nil {
            hideTask?.cancel()
            hideTask = nil
        }
        if changedKind, let delay = state.hidesAfter {
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
        shownState = nil
        announcements.reset()
        panel?.orderOut(nil)
    }

    /// Which screen the state is: the recording and its updates are one screen, every problem its own.
    static func screen(_ state: MeetingHUDState) -> String {
        switch state {
        case .allowMicrophone: "allowMicrophone"
        case .recording: "recording"
        case .finishing: "finishing"
        case .processing: "processing"
        case .saved: "saved"
        case .savedIncomplete: "savedIncomplete"
        case .problem(let problem): "problem.\(problem)"
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.singleLineHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: MeetingHUDView(model: model))
        return panel
    }

    /// Positions the panel when it appears; afterwards only the height may change, with the top edge fixed, so
    /// the pill does not jump to another screen when the mouse moves.
    private func layout(_ panel: NSPanel, for state: MeetingHUDState) {
        let height = state.hasDetailLine ? Self.twoLineHeight : Self.singleLineHeight
        guard panel.isVisible else { return place(panel, height: height) }
        let current = panel.frame
        guard abs(current.height - height) > 0.5 else { return }
        panel.setContentSize(NSSize(width: Self.width, height: height))
        panel.setFrameOrigin(NSPoint(x: current.minX, y: current.maxY - panel.frame.height))
    }

    /// Top centre of the screen the mouse is on, under the menu bar; the dictation HUD sits at the bottom.
    private func place(_ panel: NSPanel, height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setContentSize(NSSize(width: Self.width, height: height))
        panel.setFrameOrigin(
            NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - height - Self.margin))
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

struct MeetingHUDView: View {
    let model: MeetingHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var still: Bool { reduceMotion || model.reducesMotion }

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                icon(for: state)
                    .frame(width: 20, height: 20)
                if case .recording(let recording) = state {
                    recordingRow(recording)
                } else {
                    Text(state.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                ForEach(Array(state.actions.enumerated()), id: \.offset) { _, action in
                    actionButton(action, in: state)
                }
            }
            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 400, height: state.hasDetailLine ? 68 : 44, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.6), lineWidth: 1)
            }
        }
        .animation(still ? nil : .smooth(duration: 0.2), value: state.hasDetailLine)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.accessibilityLabel)
    }

    private func recordingRow(_ recording: MeetingHUDState.Recording) -> some View {
        HStack(spacing: 10) {
            Text(MeetingHUDState.clock(recording.elapsedSeconds))
                .font(.callout.monospacedDigit().weight(.medium))
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            if recording.recordsMicrophone {
                LevelMeter(
                    label: String(localized: "Me", comment: "Meeting HUD level meter of the microphone"),
                    level: recording.micLevel, animated: !still)
            }
            if recording.recordsSystem {
                LevelMeter(
                    label: String(localized: "System", comment: "Meeting HUD level meter of the system audio"),
                    level: recording.systemLevel, animated: !still)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: MeetingHUDState.Action, in state: MeetingHUDState) -> some View {
        let title = state.title(for: action)
        switch action {
        case .stop:
            Button(title) { model.onAction(action) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
        default:
            Button(title) { model.onAction(action) }
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
        }
    }

    @ViewBuilder
    private func icon(for state: MeetingHUDState) -> some View {
        switch state {
        case .recording:
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.red)
                .font(.title3)
                .symbolEffect(.pulse, isActive: !still)
                .accessibilityHidden(true)
        case .finishing, .processing:
            ProgressView().controlSize(.small)
        case .saved:
            Image(systemName: state.symbolName).foregroundStyle(.green)
                .font(.title3).accessibilityHidden(true)
        case .savedIncomplete, .allowMicrophone:
            Image(systemName: state.symbolName).foregroundStyle(.orange)
                .font(.title3).accessibilityHidden(true)
        case .problem:
            Image(systemName: state.symbolName).foregroundStyle(.red)
                .font(.title3).accessibilityHidden(true)
        }
    }
}

/// A short bar that follows one track's level, with its name. Not animated when Reduce Motion is on.
private struct LevelMeter: View {
    let label: String
    let level: Float
    let animated: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 44 * CGFloat(min(1, max(0, level))))
                    .animation(animated ? .easeOut(duration: 0.08) : nil, value: level)
            }
            .frame(width: 44, height: 6)
        }
        .accessibilityHidden(true)
    }
}

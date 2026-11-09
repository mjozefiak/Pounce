import AppKit
import Foundation
import LintelUI
import SwiftUI

/// What the window-management HUD says. The text lives here, apart from the panel, so it is tested on plain
/// values. No window title and no bundle id ever appears in it.
/// What a press needed Accessibility for, so the HUD can say what is blocked.
enum AccessibilityPurpose: Equatable, Sendable {
    case switching
    case moving
}

enum WindowsHUDState: Equatable, Sendable {
    /// After a switch: the workspace number and how many windows it holds (about 600 ms).
    case workspace(number: Int, windowCount: Int)
    /// A shortcut was pressed without Accessibility: nothing moved, and a button opens the setting.
    case accessibilityNeeded(AccessibilityPurpose)
    /// *Restore all windows*, a recovery at launch or a re-grant: how many windows came back.
    case restored(restored: Int, onAnotherSpace: Int, failed: Int)
    /// Windows stay parked: Accessibility is off, so nothing can put them back.
    case parkedNeedsAccessibility
    /// Shown once, the first time a Zones layout is active: how to snap a window by dragging.
    case snapHint
    /// An earlier run is still putting windows back: nothing could be done yet.
    case stillStopping

    init(report: RecoveryReport) {
        self =
            report.needsAccessibility
            ? .parkedNeedsAccessibility
            : .restored(restored: report.restored, onAnotherSpace: report.onAnotherSpace, failed: report.failed)
    }

    var title: String {
        switch self {
        case .workspace(let number, _):
            String(localized: "Workspace \(number)", comment: "Window switcher: a workspace")
        case .accessibilityNeeded(.switching):
            String(
                localized: "Allow Accessibility to switch workspaces",
                comment: "Window HUD: a workspace shortcut was pressed without Accessibility")
        case .accessibilityNeeded(.moving):
            String(
                localized: "Allow Accessibility to move windows",
                comment: "Window HUD: a move shortcut was pressed without Accessibility")
        case .restored(let restored, _, _):
            restored > 0
                ? String(
                    localized: "\(restored) windows restored",
                    comment: "Window HUD: how many windows were put back where they were")
                : String(localized: "No windows restored", comment: "Window HUD: nothing could be put back")
        case .parkedNeedsAccessibility:
            String(localized: "Windows are parked", comment: "Window HUD: windows are hidden and cannot be restored")
        case .snapHint:
            ZoneOverlayText.hint
        case .stillStopping:
            String(
                localized: "Windows are still being put back",
                comment: "Window HUD: an earlier run has not finished restoring windows")
        }
    }

    var detail: String? {
        switch self {
        case .workspace(_, let count): return WindowSearchSource.windowCount(count)
        case .accessibilityNeeded, .snapHint: return nil
        case .stillStopping:
            return String(
                localized: "Try again in a moment.", comment: "Window HUD: what to do while windows are put back")
        case .restored(_, let otherSpace, let failed):
            var parts: [String] = []
            if otherSpace > 0 {
                parts.append(
                    String(
                        localized: "On another Space: \(otherSpace)",
                        comment: "Window HUD: windows that could not be restored because they are on another Space"))
            }
            if failed > 0 {
                parts.append(
                    String(
                        localized: "Not responding: \(failed)",
                        comment: "Window HUD: windows of apps that did not answer"))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .parkedNeedsAccessibility:
            return String(
                localized: "Allow Accessibility to put them back.",
                comment: "Window HUD: what to do about parked windows")
        }
    }

    var symbolName: String {
        switch self {
        case .workspace: "rectangle.3.group"
        case .accessibilityNeeded: "lock.fill"
        case .restored(let restored, let otherSpace, let failed):
            restored > 0 && otherSpace + failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .parkedNeedsAccessibility: "exclamationmark.triangle.fill"
        case .stillStopping: "clock.fill"
        case .snapHint: "rectangle.split.3x1"
        }
    }

    /// Whether the symbol is drawn in the attention colour (something is left to do) rather than ok.
    var needsAttention: Bool {
        switch self {
        case .workspace, .snapHint: false
        default: symbolName != "checkmark.circle.fill"
        }
    }

    /// Whether the HUD shows the *Allow Accessibility* button (and so takes mouse clicks).
    var offersAllowAccessibility: Bool {
        switch self {
        case .accessibilityNeeded, .parkedNeedsAccessibility: return true
        default: return false
        }
    }

    /// What VoiceOver hears.
    var announcement: String { [title, detail].compactMap { $0 }.joined(separator: ". ") }

    /// How long the HUD stays; a state that asks for a click stays longer.
    var hidesAfter: Duration {
        switch self {
        case .workspace: .milliseconds(600)
        case .accessibilityNeeded: .seconds(5)
        case .restored(_, let otherSpace, let failed): otherSpace + failed > 0 ? .seconds(4) : .seconds(2)
        case .parkedNeedsAccessibility: .seconds(6)
        case .snapHint, .stillStopping: .seconds(4)
        }
    }
}

/// Shows the HUD. The panel in the app, a recording fake in tests.
@MainActor
protocol WindowsHUDPresenting: AnyObject, Sendable {
    func show(_ state: WindowsHUDState)
    /// What the *Allow Accessibility* button does; the plugin sets it.
    var allowAccessibility: @MainActor () -> Void { get set }
}

/// Shows nothing: what a pane model uses until the plugin gives it its HUD.
@MainActor
final class NullHUD: WindowsHUDPresenting {
    var allowAccessibility: @MainActor () -> Void = {}
    func show(_ state: WindowsHUDState) {}
}

/// A small glass pill near the bottom of the screen with the mouse cursor, built like the dictation HUD: a
/// non-activating panel that never takes focus, never shows up in screen recordings (`sharingType = .none`) and
/// is created on first use, so a plugin that never shows it draws nothing.
@MainActor
final class WindowsHUDPanel: WindowsHUDPresenting {
    private var panel: NSPanel?
    private var hosting: NSHostingView<WindowsHUDView>?
    private var hideTask: Task<Void, Never>?
    private let reducesMotion: () -> Bool
    var allowAccessibility: @MainActor () -> Void = {}

    private let time: TimeSource

    /// - Parameter clock: the plugin's clock, which times how long a message stays.
    init(
        clock: any Clock<Duration> = ContinuousClock(),
        reducesMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        time = TimeSource(clock)
        self.reducesMotion = reducesMotion
    }

    func show(_ state: WindowsHUDState) {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        hosting?.rootView = WindowsHUDView(
            state: state, reducesMotion: reducesMotion(), allow: { [weak self] in self?.allowAccessibility() })
        panel.ignoresMouseEvents = !state.offersAllowAccessibility
        position(panel)
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: state.announcement,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        let delay = state.hidesAfter
        hideTask = Task { [weak self, time] in
            try? await time.sleep(delay)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.sharingType = .none
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let hosting = NSHostingView(rootView: WindowsHUDView(state: .parkedNeedsAccessibility, reducesMotion: false))
        self.hosting = hosting
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
    }
}

struct WindowsHUDView: View {
    let state: WindowsHUDState
    var reducesMotion = false
    var allow: @MainActor () -> Void = {}
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbolName)
                .font(.title3)
                .foregroundStyle(state.needsAttention ? LintelBrand.statusAttention : LintelBrand.statusOk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(textSize.font(.callout, weight: .medium))
                    .lineLimit(1)
                if let detail = state.detail {
                    Text(detail)
                        .font(textSize.font(.caption1))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if state.offersAllowAccessibility {
                Button(String(localized: "Allow Accessibility", comment: "Window HUD: opens the Accessibility setting"))
                {
                    allow()
                }
                .buttonStyle(.link)
                .foregroundStyle(LintelBrand.accentText)
                .font(textSize.font(.callout, weight: .medium))
            }
        }
        .padding(.horizontal, 16)
        .frame(width: state.offersAllowAccessibility ? 440 : 288, height: 44)
        .glassEffect(.regular, in: .capsule)
        .overlay {
            if contrast == .increased { Capsule().strokeBorder(LintelBrand.ink.opacity(0.6), lineWidth: 1) }
        }
        .frame(width: 480, height: 64)
        .animation(reducesMotion ? nil : .smooth(duration: 0.2), value: state)
        .accessibilityElement(children: state.offersAllowAccessibility ? .contain : .combine)
        .accessibilityLabel(state.announcement)
    }
}

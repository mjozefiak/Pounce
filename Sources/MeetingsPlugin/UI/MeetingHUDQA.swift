#if DEBUG
import AppKit
import SwiftUI

/// DEBUG only, `--qa-hud meeting:<state>` (`plugins.meetings.qaHUD`): draws the real `MeetingHUDView` in the given
/// state in a QA panel, without a microphone, system audio, a model or any permission, so `--qa-snapshot` can write
/// it to a file. The panel has the identifier the shell looks for (`QAHUDRequest.identifier`). Not a contract.
@MainActor
final class MeetingHUDQA {
    static let settingName = "qaHUD"
    static let panelIdentifier = "lintel.qa.hud"

    private static func recording(_ change: (inout MeetingHUDState.Recording) -> Void = { _ in })
        -> MeetingHUDState
    {
        var value = MeetingHUDState.Recording(elapsedSeconds: 754, micLevel: 0.55, systemLevel: 0.35)
        change(&value)
        return .recording(value)
    }

    /// Every state name `--qa-hud meeting:<name>` accepts.
    static let states: [(name: String, state: MeetingHUDState)] = [
        ("allow-microphone", .allowMicrophone),
        ("recording", recording()),
        ("recording-consent", recording { $0.showsConsent = true }),
        ("recording-loading-model", recording { $0.loadingModel = true }),
        ("recording-model-unavailable", recording { $0.modelUnavailable = false }),
        ("recording-countdown", recording { $0.secondsLeft = 120 }),
        ("recording-no-system-audio", recording { $0.noSystemAudio = true }),
        ("recording-no-microphone-audio", recording { $0.noMicrophoneAudio = true }),
        ("recording-low-disk", recording { $0.lowDisk = true }),
        ("recording-write-problem", recording { $0.writeProblem = true }),
        ("recording-device-disconnected", recording { $0.lost = [.mic] }),
        ("recording-system-audio-lost", recording { $0.lost = [.system] }),
        ("recording-microphone-only", recording { $0.recordsSystem = false }),
        ("finishing", .finishing),
        ("processing-transcribing", .processing(.transcribing(remaining: 12))),
        ("processing-speakers", .processing(.recognisingSpeakers)),
        ("processing-closing", .processing(.closing)),
        ("saved", .saved),
        ("saved-incomplete", .savedIncomplete),
        ("model-missing", .problem(.modelMissing)),
        ("model-unavailable", .problem(.modelUnavailable)),
        ("library-unavailable", .problem(.libraryUnavailable)),
        ("microphone-denied", .problem(.microphoneDenied(offersSystemOnly: false))),
        ("microphone-denied-system-only", .problem(.microphoneDenied(offersSystemOnly: true))),
        ("no-audio-input", .problem(.noAudioInput)),
        ("low-disk-at-start", .problem(.lowDiskAtStart)),
        ("still-processing", .problem(.stillProcessing)),
        ("model-being-removed", .problem(.modelBeingRemoved)),
        ("nothing-heard", .problem(.nothingHeard)),
        ("could-not-start", .problem(.couldNotStart)),
        ("failed", .problem(.failed)),
    ]

    static func state(named name: String) -> MeetingHUDState? { states.first { $0.name == name }?.state }

    private let model = MeetingHUDModel()
    private var panel: NSPanel?

    /// Shows the state; `false` for a name this HUD does not have.
    @discardableResult
    func show(named name: String) -> Bool {
        guard let state = Self.state(named: name) else { return false }
        model.reducesMotion = true
        model.state = state
        let height: CGFloat = state.hasDetailLine ? 68 : 44
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(NSSize(width: 400, height: height))
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 200, y: frame.maxY - height - 8))
        }
        panel.orderFrontRegardless()
        return true
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.identifier = NSUserInterfaceItemIdentifier(Self.panelIdentifier)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.contentView = NSHostingView(
            // `cacheDisplay` does not draw the glass, so the snapshot gets the window colour behind the real view.
            rootView: MeetingHUDView(model: model).background(
                Color(nsColor: .windowBackgroundColor)
            ))
        return panel
    }
}
#endif

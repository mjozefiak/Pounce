#if DEBUG
import AppKit
import SwiftUI

/// DEBUG only, `--qa-hud dictation:<state>` (`plugins.dictation.qaHUD`): draws the real `DictationHUDView` in the given
/// state in a QA panel, without a microphone, a model or any permission, so `--qa-snapshot` can write it to a file.
/// The panel has the identifier the shell looks for (`QAHUDRequest.identifier`). Not a contract.
@MainActor
final class DictationHUDQA {
    static let settingName = "qaHUD"
    static let panelIdentifier = "lintel.qa.hud"

    /// Every state name `--qa-hud dictation:<name>` accepts.
    static let states: [(name: String, state: HUDState)] = [
        ("allow-microphone", .allowMicrophone),
        ("recording", .recording(.init(level: 0.6))),
        ("loading-model", .recording(.init(level: 0, loadingModel: true))),
        ("countdown", .recording(.init(level: 0.4, secondsLeft: 10))),
        ("finishing", .finishing),
        ("pasted", .pasted),
        ("pasted-unformatted", .pastedUnformatted(all: true)),
        ("pasted-partly-unformatted", .pastedUnformatted(all: false)),
        ("copied-no-accessibility", .copied(.noAccessibility)),
        ("copied", .copied(.targetGone)),
        ("model-missing", .problem(.modelMissing)),
        ("model-unavailable", .problem(.modelUnavailable)),
        ("model-failed", .problem(.modelFailedToLoad)),
        ("speech-model-busy", .problem(.speechModelBusy)),
        ("microphone-denied", .problem(.microphoneDenied)),
        ("no-microphone", .problem(.noMicrophone)),
        ("nothing-heard", .problem(.nothingHeard)),
        ("nothing-to-paste", .problem(.nothingToPaste)),
    ]

    static func state(named name: String) -> HUDState? { states.first { $0.name == name }?.state }

    private let model = HUDModel()
    private var panel: NSPanel?

    /// Shows the state; `false` for a name this HUD does not have.
    @discardableResult
    func show(named name: String) -> Bool {
        guard let state = Self.state(named: name) else { return false }
        model.reducesMotion = true
        model.state = state
        // A fixed running time, so a snapshot is the same every run.
        model.recordingStartedAt = state.offersCancel ? Date().addingTimeInterval(-83) : nil
        let panel = panel ?? makePanel()
        self.panel = panel
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 140, y: frame.minY + 48))
        }
        panel.orderFrontRegardless()
        return true
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
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
            rootView: DictationHUDView(model: model).background(
                Color(nsColor: .windowBackgroundColor)
            ))
        return panel
    }
}
#endif

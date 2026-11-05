import AppKit
import LintelUI
import Observation
import SwiftUI

/// Opens meeting windows: one per meeting, reused when it is already open. Only `MeetingsLibraryActions`
/// creates it (one per plugin); nothing else, the record flow and the HUD included, opens a meeting window.
@MainActor
final class MeetingWindowController: NSObject, NSWindowDelegate, MeetingWindowPresenting {
    private var windows: [Int64: NSWindow] = [:]
    private var models: [Int64: MeetingWindowModel] = [:]
    private let makeModel: @MainActor (Int64) -> MeetingWindowModel

    /// The app's text size, when the host passes it; the view uses text styles, so it scales.
    var textSize: TextSize = .default
    /// False in QA mode: the window is ordered front without activating Lintel.
    var activatesApp = true

    init(makeModel: @escaping @MainActor (Int64) -> MeetingWindowModel) {
        self.makeModel = makeModel
    }

    func isOpen(_ meetingID: Int64) -> Bool { windows[meetingID]?.isVisible ?? false }

    func show(meetingID: Int64) {
        if let existing = windows[meetingID] {
            bringForward(existing)
            return
        }
        let model = makeModel(meetingID)
        let view = MeetingWindowView(model: model).lintelTextSize(textSize)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Meeting", comment: "Meeting window title while loading")
        window.setContentSize(NSSize(width: 640, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.center()
        // One frame per meeting: two open meetings do not share a position, and a reopened one comes back.
        window.setFrameAutosaveName("MeetingWindow-\(meetingID)")
        window.identifier = NSUserInterfaceItemIdentifier(String(meetingID))
        windows[meetingID] = window
        models[meetingID] = model
        keepTitle(of: window, in: model)
        bringForward(window)
    }

    /// The window title follows the meeting title (also after a rename).
    private func keepTitle(of window: NSWindow, in model: MeetingWindowModel) {
        withObservationTracking {
            _ = model.title
        } onChange: { [weak self, weak window, weak model] in
            Task { @MainActor in
                guard let self, let window, let model else { return }
                window.title = model.title
                self.keepTitle(of: window, in: model)
            }
        }
    }

    func close(meetingID: Int64) {
        windows[meetingID]?.close()
    }

    func closeAll() {
        for window in Array(windows.values) { window.close() }
    }

    private func bringForward(_ window: NSWindow) {
        if activatesApp {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let key = windows.first(where: { $0.value === window })?.key
        else { return }
        windows[key] = nil
        // A title typed but not submitted is saved; the model outlives the window for this one task.
        if let model = models.removeValue(forKey: key) {
            Task { @MainActor in await model.commitPendingTitle() }
        }
    }

    /// Posts a VoiceOver announcement from the window (used for the model's `announce`).
    static func announce(_ text: String) {
        guard let element = NSApp.keyWindow else { return }
        NSAccessibility.post(
            element: element, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

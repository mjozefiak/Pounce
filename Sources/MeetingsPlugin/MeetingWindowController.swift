import AppKit
import Observation
import SwiftUI

/// Opens meeting windows: one per meeting, reused when it is already open. Not wired to anything yet (the
/// library and the command come with step 1.10).
@MainActor
final class MeetingWindowController: NSObject, NSWindowDelegate {
    private var windows: [Int64: NSWindow] = [:]
    private let makeModel: @MainActor (Int64) -> MeetingWindowModel

    /// The app's text size, when the host passes it; the view uses text styles, so it scales.
    var dynamicTypeSize: DynamicTypeSize?
    /// False in QA mode: the window is ordered front without activating Pounce.
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
        let view = MeetingWindowView(model: model).modifier(TextSizeModifier(size: dynamicTypeSize))
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Meeting", comment: "Meeting window title while loading")
        window.setContentSize(NSSize(width: 640, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("MeetingWindow")
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier(String(meetingID))
        windows[meetingID] = window
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
    }

    /// Posts a VoiceOver announcement from the window (used for the model's `announce`).
    static func announce(_ text: String) {
        guard let element = NSApp.keyWindow else { return }
        NSAccessibility.post(
            element: element, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

private struct TextSizeModifier: ViewModifier {
    let size: DynamicTypeSize?

    func body(content: Content) -> some View {
        if let size { content.dynamicTypeSize(size) } else { content }
    }
}

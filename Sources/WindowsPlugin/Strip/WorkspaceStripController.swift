import AppKit
import Foundation
import LintelKit
import Synchronization

/// The menu bar strip of numbered boxes (spec Q16): one `NSStatusItem` whose template image shows every box, the
/// active one filled. Clicks are mapped from their position on the single button (`StripLayout.index`); each box
/// is also an accessibility element of the button, and the right-click menu is the guaranteed alternative for
/// VoiceOver. Created by `activate()` and removed by `deactivate()`.
///
/// What a real menu bar does with a status item (click positions, accessibility children, room in the menu bar)
/// cannot be checked without a display; the fallback of one status item per box is a manual decision recorded in
/// `docs/qa.md`, taken when the click mapping or the children do not work on a real Mac.
@MainActor
final class WorkspaceStripController: NSObject {
    private var statusItem: NSStatusItem?
    private(set) var boxes: [StripBox] = []
    /// The accessibility children, kept between redraws (VoiceOver focus survives a redraw that changes nothing about the set).
    private(set) var elements: [StripBoxElement] = []
    private let select: @MainActor (Int) -> Void
    private let restoreAll: @MainActor () -> Void
    private let announce: Bool
    private var lastCurrent: Int?
    /// Where the mouse went down on the item (a local monitor; see `StripLayout.resolvedClickX`).
    private let capture = PressCapture()
    private var downMonitor: Any?
    /// Whether the item is on screen, `nil` while unknown (see `StripVisibility`).
    private(set) var hasRoom: Bool?
    var onRoomChange: @MainActor (Bool?) -> Void = { _ in }
    /// What the item looks like and where the screens are; replaced by a test.
    var itemState: @MainActor () -> StripItemState? = { nil }
    var screenFrames: @MainActor () -> [CGRect] = { NSScreen.screens.map(\.frame) }
    /// Runs `work` after `delay` seconds; replaced by a test.
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }
    /// How long a "no room" answer waits for a second look: an item that was just created or is sliding with the
    /// menu bar has an odd frame for a moment.
    static let roomRecheckDelay: TimeInterval = 1
    private var recheckPending = false
    private var observers: [any NSObjectProtocol] = []

    init(
        select: @escaping @MainActor (Int) -> Void, restoreAll: @escaping @MainActor () -> Void, announce: Bool = true
    ) {
        self.select = select
        self.restoreAll = restoreAll
        self.announce = announce
    }

    var isInstalled: Bool { statusItem != nil }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(StripModel.itemDescription(boxes))
        }
        statusItem = item
        itemState = { [weak item] in
            guard let window = item?.button?.window else { return nil }
            return StripItemState(frame: window.frame, hasScreen: window.screen != nil, isVisible: window.isVisible)
        }
        observeRoomChanges()
        let capture = capture
        downMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak item] event in
            // Local monitors run on the main thread; nothing here touches main-actor state.
            if let window = item?.button?.window, event.window === window { capture.set(NSEvent.mouseLocation.x) }
            return event
        }
        redraw()
    }

    func remove() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        downMonitor = nil
        capture.reset()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        hasRoom = nil
    }

    /// Shows `boxes`; announces a switch.
    func update(_ boxes: [StripBox]) {
        let current = boxes.first(where: \.isCurrent)?.number
        let switched = lastCurrent != nil && current != lastCurrent
        self.boxes = boxes
        lastCurrent = current
        redraw()
        if switched, announce, let button = statusItem?.button, let number = current {
            NSAccessibility.post(
                element: button, notification: .announcementRequested,
                userInfo: [
                    NSAccessibility.NotificationUserInfoKey.announcement: String(
                        localized: "Workspace \(number)", comment: "Window switcher: a workspace")
                ])
        }
    }

    private func redraw() {
        guard let button = statusItem?.button else { return }
        let image = StripImage.render(boxes)
        button.image = image
        let description = StripModel.itemDescription(boxes)
        image.accessibilityDescription = description
        button.setAccessibilityLabel(description)
        button.imagePosition = .imageOnly
        let originX = imageOriginX(in: button, image: image)
        let reconciled = StripBoxElement.reconcile(
            elements, boxes: boxes, originX: originX, y: (button.bounds.height - StripLayout.boxHeight) / 2,
            parent: button, select: select)
        elements = reconciled.elements
        // The children are set only when the set changed: setting them again drops VoiceOver's focus.
        if reconciled.rebuilt { button.setAccessibilityChildren(elements) }
        // The item's window exists only after layout; check on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in self?.checkRoom() }
    }

    /// Where the image starts inside the button: the rect the button's own cell draws it in when it can say, else the
    /// image centred (`StripLayout.imageOriginX`). The click and the accessibility children must agree with what is
    /// on screen, so the cell's answer wins.
    private func imageOriginX(in button: NSStatusBarButton, image: NSImage) -> CGFloat {
        let drawn = (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds)
        return StripLayout.imageOriginX(
            buttonWidth: button.bounds.width, imageWidth: image.size.width, drawnImageMinX: drawn?.minX,
            drawnImageWidth: drawn?.width)
    }

    /// Looks again whenever the answer can change: the screens change, the item's window moves or changes screen
    /// (the menu bar sliding in or out, another item pushing it), and on every redraw.
    private func observeRoomChanges() {
        let center = NotificationCenter.default
        let names = [
            NSApplication.didChangeScreenParametersNotification, NSWindow.didMoveNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification,
        ]
        // Any window of the app moving is a reason to look (cheap: nothing changes unless the answer does).
        for name in names {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.checkRoom() }
                })
        }
    }

    /// Settings asks for the answer as it is now (the pane appeared, Lintel became active): no waiting.
    func refreshRoom() -> Bool? {
        evaluateRoom(confirmed: true)
        return hasRoom
    }

    func checkRoom() { evaluateRoom(confirmed: false) }

    /// `true` is taken at once. `false` is taken only when it is still the answer after `roomRecheckDelay` (or
    /// `confirmed`), so an item that is not placed yet does not raise the banner.
    private func evaluateRoom(confirmed: Bool) {
        guard let state = itemState() else { return }
        let screens = screenFrames()
        let room = StripVisibility.hasRoom(state, screens: screens)
        #if DEBUG
        StripTrace.record(
            "room frame=\(String(describing: state.frame)) hasScreen=\(state.hasScreen) visible=\(state.isVisible) "
                + "screens=\(screens) -> \(room) confirmed=\(confirmed) was=\(String(describing: hasRoom))")
        #endif
        if room || confirmed {
            apply(room)
        } else if hasRoom != false, !recheckPending {
            recheckPending = true
            schedule(Self.roomRecheckDelay) { [weak self] in
                guard let self else { return }
                self.recheckPending = false
                self.evaluateRoom(confirmed: true)
            }
        }
    }

    private func apply(_ room: Bool) {
        guard room != hasRoom else { return }
        hasRoom = room
        onRoomChange(room)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let press = capture.take()
        let fresh = event.map { ProcessInfo.processInfo.systemUptime - $0.timestamp < 1 } ?? false
        let isMouseUp = event?.type == .leftMouseUp && event?.window === sender.window && fresh
        #if DEBUG
        StripTrace.record(
            "action type=\(String(describing: event?.type)) fresh=\(fresh) inItem=\(event?.window === sender.window) "
                + "press=\(String(describing: press)) mouse=\(NSEvent.mouseLocation) "
                + "window=\(String(describing: sender.window?.frame))")
        #endif
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu(from: sender)
            return
        }
        let buttonX = StripLayout.resolvedClickX(
            pressScreenX: press, cursorScreenX: NSEvent.mouseLocation.x, itemFrame: sender.window?.frame,
            buttonMinX: sender.frame.minX)
        switch StripLayout.clickAction(isFreshMouseUp: isMouseUp, buttonX: buttonX) {
        case .menu:
            showMenu(from: sender)
        case .ignore:
            return
        case .map(let x):
            guard let image = sender.image else { return }
            let mapped = x - imageOriginX(in: sender, image: image)
            #if DEBUG
            StripTrace.record("click mappedX=\(mapped)")
            #endif
            if let index = StripLayout.index(atX: mapped, boxCount: boxes.count), boxes.indices.contains(index) {
                select(boxes[index].number)
            }
        }
    }

    /// The screen rect of every box (QA: where to click), `nil` while the item has no window.
    func boxScreenRects() -> [CGRect]? {
        guard let button = statusItem?.button, let window = button.window, let image = button.image else { return nil }
        return StripLayout.boxScreenRects(
            boxCount: boxes.count, itemFrame: window.frame,
            imageOriginX: imageOriginX(in: button, image: image) + button.frame.minX)
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        for box in boxes {
            let item = NSMenuItem(
                title: String(
                    localized: "Go to Workspace \(box.number)", comment: "Command: switches to a numbered workspace"),
                action: #selector(menuSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = box.number
            item.state = box.isCurrent ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let restore = NSMenuItem(
            title: String(
                localized: "Restore All Windows", comment: "Menu item and command: puts every parked window back"),
            action: #selector(menuRestore), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuSelected(_ sender: NSMenuItem) { select(sender.tag) }
    @objc private func menuRestore() { restoreAll() }
}

/// The screen x where the mouse last went down on the strip's item, for one click. Thread-safe: the event monitor
/// that fills it is not main-actor isolated.
final class PressCapture: Sendable {
    private let value = Mutex<CGFloat?>(nil)
    func set(_ x: CGFloat) { value.withLock { $0 = x } }
    func reset() { value.withLock { $0 = nil } }
    /// The captured x, once (a second click without a new press has none).
    func take() -> CGFloat? {
        value.withLock {
            let x = $0
            $0 = nil
            return x
        }
    }
}

/// One box as an accessibility element: pressing it switches to its workspace.
@MainActor
final class StripBoxElement: NSAccessibilityElement {
    let number: Int
    private let select: @MainActor (Int) -> Void

    init(number: Int, select: @escaping @MainActor (Int) -> Void) {
        self.number = number
        self.select = select
        super.init()
    }

    /// Brings `existing` up to date with `boxes`. When the numbers are the same, the very same elements are updated in
    /// place (label, selected state, frame) and `rebuilt` is false; otherwise new ones are made.
    static func reconcile(
        _ existing: [StripBoxElement], boxes: [StripBox], originX: CGFloat, y: CGFloat, parent: Any?,
        select: @escaping @MainActor (Int) -> Void
    ) -> (elements: [StripBoxElement], rebuilt: Bool) {
        let rebuilt = existing.map(\.number) != boxes.map(\.number)
        let elements = rebuilt ? boxes.map { StripBoxElement(number: $0.number, select: select) } : existing
        for (index, (element, box)) in zip(elements, boxes).enumerated() {
            if rebuilt {
                element.setAccessibilityParent(parent)
                element.setAccessibilityRole(.button)
            }
            element.setAccessibilityLabel(StripModel.accessibilityLabel(box))
            element.setAccessibilitySelected(box.isCurrent)
            element.setAccessibilityFrameInParentSpace(
                NSRect(
                    x: originX + StripLayout.originX(ofBox: index), y: y, width: StripLayout.boxWidth,
                    height: StripLayout.boxHeight))
        }
        return (elements, rebuilt)
    }

    /// AppKit's override point is not main-actor isolated, so the switch is handed to the main actor instead of
    /// being called here (`MainActor.assumeIsolated` would trap if a caller were ever off the main thread).
    nonisolated override func accessibilityPerformPress() -> Bool {
        let (select, number) = (self.select, self.number)
        Task { @MainActor in select(number) }
        return true
    }
}

/// Draws the strip as a template image: the active box filled with its number cut out, the others outlined.
enum StripImage {
    @MainActor static func render(_ boxes: [StripBox]) -> NSImage {
        let size = NSSize(width: max(1, StripLayout.width(boxCount: boxes.count)), height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            for (index, box) in boxes.enumerated() {
                let frame = NSRect(
                    x: StripLayout.originX(ofBox: index), y: (rect.height - StripLayout.boxHeight) / 2,
                    width: StripLayout.boxWidth, height: StripLayout.boxHeight)
                draw(box, in: frame)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(
            localized: "Workspaces", comment: "Strip: accessibility label of the menu bar item")
        return image
    }

    private static func draw(_ box: StripBox, in frame: NSRect) {
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        let text = NSAttributedString(
            string: String(box.number),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.black,
            ])
        let textFrame = NSRect(
            x: frame.midX - text.size().width / 2, y: frame.midY - text.size().height / 2, width: text.size().width,
            height: text.size().height)
        if box.isCurrent {
            NSColor.black.setFill()
            path.fill()
            // The number is cut out of the fill, so the state never depends on colour.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(in: textFrame)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            NSColor.black.setStroke()
            path.lineWidth = 1
            path.stroke()
            text.draw(in: textFrame)
        }
    }
}

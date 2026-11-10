import CoreGraphics
import Foundation

/// One box of the menu bar strip.
struct StripBox: Equatable, Sendable {
    var number: Int
    var windowCount: Int
    /// The workspace the user is on: drawn filled. Never colour alone: every other box is an outline.
    var isCurrent: Bool
    /// Shown on another display right now (still an outline; the accessibility label says so).
    var isShownElsewhere: Bool
}

/// Which boxes the strip draws and which one is active (spec Q16), on plain values.
enum StripModel {
    /// - Parameters:
    ///   - occupiedOnly: `plugins.windows.strip.mode == occupied`: only workspaces that hold a window, plus the
    ///     current one and any shown on a display. The default `all` shows every configured workspace, so the
    ///     boxes never move under the cursor.
    static func boxes(summary: WorkspaceSummary, workspaceCount: Int, occupiedOnly: Bool) -> [StripBox] {
        let shown = Set(summary.visible.values)
        return WorkspaceID.all(count: workspaceCount).compactMap { workspace in
            let count = summary.counts[workspace] ?? 0
            let isCurrent = workspace == summary.current
            if occupiedOnly, count == 0, !isCurrent, !shown.contains(workspace) { return nil }
            return StripBox(
                number: workspace.rawValue, windowCount: count, isCurrent: isCurrent,
                isShownElsewhere: shown.contains(workspace) && !isCurrent)
        }
    }

    /// What VoiceOver says for the whole menu bar item (the system shows a status item no children): "Workspaces,
    /// current: 2 of 4"; just "Workspaces" while no box is current. Updated on every change.
    static func itemDescription(_ boxes: [StripBox]) -> String {
        guard let current = boxes.first(where: \.isCurrent)?.number else {
            return String(localized: "Workspaces", comment: "Strip: accessibility label of the menu bar item")
        }
        return String(
            localized: "Workspaces, current: \(current) of \(boxes.count)",
            comment: "Strip: spoken description of the menu bar item (the current workspace and how many there are)")
    }

    /// "Workspace 3, 4 windows" (spec: UI/UX). That the box is the current one is not in the label: the element's
    /// *selected* state says it (Apple's guidance), so VoiceOver does not speak it twice.
    static func accessibilityLabel(_ box: StripBox) -> String {
        var parts = [
            String(localized: "Workspace \(box.number)", comment: "Window switcher: a workspace"),
            WindowSearchSource.windowCount(box.windowCount),
        ]
        if !box.isCurrent, box.isShownElsewhere {
            parts.append(
                String(
                    localized: "shown on another display", comment: "Strip: spoken for a workspace on another display"))
        }
        return parts.joined(separator: ", ")
    }
}

/// The geometry of the strip image and the mapping from a click to a box. Pure.
enum StripLayout {
    static let boxWidth: CGFloat = 18
    static let boxHeight: CGFloat = 14
    static let gap: CGFloat = 2
    static let padding: CGFloat = 2

    static func width(boxCount: Int) -> CGFloat {
        guard boxCount > 0 else { return 0 }
        return padding * 2 + CGFloat(boxCount) * boxWidth + CGFloat(boxCount - 1) * gap
    }

    /// Where the image starts inside the button, in the button's coordinates. `drawnImageMinX` is what the button's
    /// cell reports for the image rect (`nil` when it cannot say, or when its width differs from the image's by more
    /// than a point: it then drew something else); without it the image is centred.
    static func imageOriginX(
        buttonWidth: CGFloat, imageWidth: CGFloat, drawnImageMinX: CGFloat? = nil, drawnImageWidth: CGFloat? = nil
    ) -> CGFloat {
        if let minX = drawnImageMinX, let width = drawnImageWidth, abs(width - imageWidth) <= 1, minX >= 0 {
            return minX
        }
        return max(0, (buttonWidth - imageWidth) / 2)
    }

    /// Where on the button a click landed, or `nil` when the strip cannot tell (then the strip opens its menu, which
    /// names every workspace). The position where the mouse went *down* inside the item's window wins (a fast move
    /// before the release must not change the box); else the cursor's position when inside the window. A press that
    /// comes from Accessibility or Voice Control has neither (the cursor is somewhere else), so it never reads the
    /// event's centre as "the middle box": a box is pressed through its own element, the button through the menu.
    static func resolvedClickX(
        pressScreenX: CGFloat?, cursorScreenX: CGFloat?, itemFrame: CGRect?, buttonMinX: CGFloat = 0
    ) -> CGFloat? {
        guard let itemFrame, itemFrame.width > 0 else { return nil }
        for candidate in [pressScreenX, cursorScreenX] {
            if let x = candidate, x >= itemFrame.minX, x <= itemFrame.maxX { return x - itemFrame.minX - buttonMinX }
        }
        return nil
    }

    /// What the button's action does. A fresh mouse release inside the item is mapped to a box; one whose position is
    /// not inside the item (the cursor 2 pt outside it, or the item still sliding into a revealing menu bar) does
    /// nothing, rather than reading the event's centre as the middle box; anything that is not a mouse release on the
    /// item (VoiceOver, Voice Control, the keyboard) opens the menu, which names every workspace. A box is pressed
    /// through its own accessibility element, by identity.
    enum ClickAction: Equatable {
        case map(CGFloat)
        case ignore
        case menu
    }

    static func clickAction(isFreshMouseUp: Bool, buttonX: CGFloat?) -> ClickAction {
        guard isFreshMouseUp else { return .menu }
        guard let buttonX else { return .ignore }
        return .map(buttonX)
    }

    /// The screen rect of every box when the item's window is at `itemFrame` and the image starts `imageOriginX` into
    /// it (`y` is the window's, boxes are centred vertically).
    static func boxScreenRects(boxCount: Int, itemFrame: CGRect, imageOriginX: CGFloat) -> [CGRect] {
        (0..<boxCount).map { index in
            CGRect(
                x: itemFrame.minX + imageOriginX + originX(ofBox: index),
                y: itemFrame.midY - boxHeight / 2, width: boxWidth, height: boxHeight)
        }
    }

    /// The left edge of box `index` in image coordinates.
    static func originX(ofBox index: Int) -> CGFloat { padding + CGFloat(index) * (boxWidth + gap) }

    /// The box under a click at `x` points from the left edge of the image: the box itself, or the nearer one when
    /// the click falls in a gap or the padding. `nil` outside the image.
    static func index(atX x: CGFloat, boxCount: Int) -> Int? {
        guard boxCount > 0, x >= 0, x <= width(boxCount: boxCount) else { return nil }
        let raw = Int(((x - padding + gap / 2) / (boxWidth + gap)).rounded(.down))
        return min(max(raw, 0), boxCount - 1)
    }
}

/// What the controller can see of its status item (a value, so the decision is testable).
struct StripItemState: Equatable, Sendable {
    /// The item window's frame, `nil` while it has no window.
    var frame: CGRect?
    /// Whether the window reports a screen, and whether it is on screen (ordered in).
    var hasScreen: Bool
    var isVisible: Bool
}

/// Whether the status item can be seen: macOS drops items that do not fit (the notch, many items), and the item's
/// window then lies outside every screen or has no size. Pure; the controller feeds it the window's state.
enum StripVisibility {
    /// The item has room when it has a size and sits over a screen's horizontal range in the menu bar band (the top
    /// of the screen, in AppKit's y-up coordinates) or above it. An auto-hidden menu bar slides the item's window
    /// above the screen: it still has room, only the bar is hidden (QA: a false "no room" banner). An item macOS
    /// dropped is placed off the screen sideways or has no size.
    static func hasRoom(itemFrame: CGRect?, screens: [CGRect]) -> Bool {
        guard let itemFrame, itemFrame.width > 1, itemFrame.height > 1 else { return false }
        let band: CGFloat = 60
        return screens.contains {
            itemFrame.midX >= $0.minX && itemFrame.midX <= $0.maxX && itemFrame.minY >= $0.maxY - band
        }
    }

    /// The same with what the window itself says: an item whose window is on screen and reports a screen is placed
    /// and therefore has room, whatever its frame looks like at that moment (a window that was not placed yet, or
    /// one that slides with an auto-hidden bar, has an odd frame). Only an item with no size, or one placed off every
    /// screen sideways and reporting none, has no room.
    static func hasRoom(_ item: StripItemState?, screens: [CGRect]) -> Bool {
        guard let item, let frame = item.frame, frame.width > 1, frame.height > 1 else { return false }
        if item.isVisible && item.hasScreen { return true }
        return hasRoom(itemFrame: frame, screens: screens)
    }
}

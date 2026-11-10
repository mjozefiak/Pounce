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

    /// "Workspace 3, 4 windows, current" (spec: UI/UX).
    static func accessibilityLabel(_ box: StripBox) -> String {
        var parts = [
            String(localized: "Workspace \(box.number)", comment: "Window switcher: a workspace"),
            WindowSearchSource.windowCount(box.windowCount),
        ]
        if box.isCurrent {
            parts.append(String(localized: "current", comment: "Strip: spoken after the workspace the user is on"))
        } else if box.isShownElsewhere {
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

    /// The x of a click in the button's coordinates. A status item can deliver the click with its position at the
    /// item's centre whatever was clicked (QA, real clicks on macOS 26: every left click on the strip selected the
    /// middle box), so the position the event carries is not trusted when the cursor itself says otherwise: the
    /// cursor's screen x, when it lies inside the item's window, gives the x directly. Without a usable cursor
    /// position the event's x is used. `buttonMinX` is where the button starts inside its window.
    static func clickX(
        eventX: CGFloat, cursorScreenX: CGFloat?, itemFrame: CGRect?, buttonMinX: CGFloat = 0
    ) -> CGFloat {
        guard let cursorScreenX, let itemFrame, itemFrame.width > 0, cursorScreenX >= itemFrame.minX,
            cursorScreenX <= itemFrame.maxX
        else { return eventX }
        return cursorScreenX - itemFrame.minX - buttonMinX
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

/// Whether the status item can be seen: macOS drops items that do not fit (the notch, many items), and the item's
/// window then lies outside every screen or has no size. Pure; the controller feeds it the window's frame.
enum StripVisibility {
    static func hasRoom(itemFrame: CGRect?, screens: [CGRect]) -> Bool {
        guard let itemFrame, itemFrame.width > 1, itemFrame.height > 1 else { return false }
        return screens.contains { $0.contains(CGPoint(x: itemFrame.midX, y: itemFrame.midY)) }
    }
}

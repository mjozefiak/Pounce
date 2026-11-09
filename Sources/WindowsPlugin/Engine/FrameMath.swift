import CoreGraphics
import Foundation
import LintelKit

/// Pure geometry for parking, restoring and placing windows. Everything is in the Accessibility coordinate
/// space (origin at the top left of the main display, y grows downwards), the space of `WindowInfo.frame`.
enum FrameMath {
    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }

    static func originsApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance && abs(lhs.origin.y - rhs.origin.y) <= tolerance
    }

    /// The display a frame mostly lies on: the one with the largest overlap, else the one containing its
    /// centre, else the main display, else the first.
    static func display(for frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (display: DisplayInfo, area: CGFloat)?
        for display in displays {
            let overlap = display.frame.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (display, area) }
        }
        if let best { return best.display }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return displays.first { $0.frame.contains(centre) } ?? displays.first { $0.isMain } ?? displays.first
    }

    /// The frame a hidden window is moved to: the same size, with only `sliver` points of it left on the
    /// display, at its bottom right corner.
    static func parkedFrame(for frame: CGRect, on display: DisplayInfo, sliver: CGFloat) -> CGRect {
        CGRect(
            x: display.frame.maxX - sliver, y: display.frame.maxY - sliver, width: frame.width,
            height: frame.height)
    }

    /// `frame` moved (and, when it is larger than `area`, shrunk) to lie inside `area`.
    static func clamp(_ frame: CGRect, into area: CGRect) -> CGRect {
        guard !area.isEmpty else { return frame }
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        let x = min(max(frame.origin.x, area.minX), area.maxX - width)
        let y = min(max(frame.origin.y, area.minY), area.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// A rectangle of `size` centred in `rect`.
    static func centered(size: CGSize, in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
            height: size.height)
    }

    /// Where a parked window's home frame goes back to: inside the visible area of the display it lies on, or of
    /// the first connected display when that display is gone.
    static func restoredFrame(home: CGRect, displays: [DisplayInfo]) -> CGRect {
        guard let display = display(for: home, in: displays) else { return home }
        return clamp(home, into: display.visibleFrame)
    }
}

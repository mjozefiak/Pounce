import CoreGraphics
import Foundation

/// Conversions between the Accessibility space (origin at the top left of the main display, y down, the space of
/// every frame in the engine) and Cocoa's screen space (origin at the bottom left of the main display, y up).
/// Pure, so the overlay's geometry is tested without a display.
enum ScreenSpace {
    /// A Cocoa point (`NSEvent.mouseLocation`) as an Accessibility point. `mainHeight` is the height of the main
    /// display (the first of `NSScreen.screens`).
    static func axPoint(fromCocoa point: CGPoint, mainHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainHeight - point.y)
    }

    /// An Accessibility rectangle as a Cocoa rectangle.
    static func cocoaRect(fromAX rect: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A Cocoa rectangle as an Accessibility rectangle.
    static func axRect(fromCocoa rect: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The index of the screen (Cocoa frames) that holds the centre of an Accessibility area, else the one with
    /// the largest overlap, else `nil`.
    static func screenIndex(forAX area: CGRect, screenFrames: [CGRect], mainHeight: CGFloat) -> Int? {
        let cocoa = cocoaRect(fromAX: area, mainHeight: mainHeight)
        let centre = CGPoint(x: cocoa.midX, y: cocoa.midY)
        if let index = screenFrames.firstIndex(where: { $0.contains(centre) }) { return index }
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in screenFrames.enumerated() {
            let overlap = frame.intersection(cocoa)
            let size = overlap.isNull ? 0 : overlap.width * overlap.height
            if size > (best?.area ?? 0) { best = (index, size) }
        }
        return best?.index
    }

    /// A zone's frame (Accessibility space) in the top-left space of the panel that covers a screen: the origin
    /// of the panel's content is the screen's top left corner.
    static func localRect(_ rect: CGRect, screenFrame: CGRect, mainHeight: CGFloat) -> CGRect {
        let origin = axRect(fromCocoa: screenFrame, mainHeight: mainHeight).origin
        return CGRect(x: rect.minX - origin.x, y: rect.minY - origin.y, width: rect.width, height: rect.height)
    }
}

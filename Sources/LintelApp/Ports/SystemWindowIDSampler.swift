import ApplicationServices
import CoreGraphics
import Foundation

/// Takes real samples for the start-up self-check: on-screen windows from `CGWindowList` matched with the
/// Accessibility windows of their app by frame, so the answer of the private function can be compared with the
/// number `CGWindowList` gives. It needs Accessibility; without it no sample is found and the check stays
/// unverified (`WindowIDSelfCheck`). A manual item in `docs/qa.md` (the real system cannot be exercised in unit
/// tests). Never logs window titles or bundle ids.
nonisolated struct SystemWindowIDSampler: WindowIDSampling {
    /// How many windows are compared at most; a few are enough to catch a wrong answer.
    static let sampleLimit = 8
    /// Frames that differ by less than this many points are the same window.
    static let frameTolerance: CGFloat = 1.5

    struct ListedWindow: Equatable {
        var number: UInt32
        var pid: Int32
        var bounds: CGRect
    }

    func samples(using lookup: WindowIDLookup) -> [WindowIDSample] {
        let listed = Self.onScreenWindows()
        var samples: [WindowIDSample] = []
        for (pid, windows) in Dictionary(grouping: listed, by: \.pid).sorted(by: { $0.key < $1.key }) {
            guard samples.count < Self.sampleLimit else { break }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                let elements = value as? [AXUIElement]
            else { continue }
            for element in elements {
                guard let frame = Self.frame(of: element),
                    let match = Self.uniqueMatch(for: frame, in: windows)
                else { continue }
                samples.append(WindowIDSample(reported: lookup.windowID(of: element), expected: match.number))
                if samples.count >= Self.sampleLimit { break }
            }
        }
        return samples
    }

    /// The one listed window whose bounds equal `frame`; `nil` when none or several do (then it proves nothing).
    static func uniqueMatch(for frame: CGRect, in windows: [ListedWindow]) -> ListedWindow? {
        let matches = windows.filter {
            abs($0.bounds.origin.x - frame.origin.x) <= frameTolerance
                && abs($0.bounds.origin.y - frame.origin.y) <= frameTolerance
                && abs($0.bounds.width - frame.width) <= frameTolerance
                && abs($0.bounds.height - frame.height) <= frameTolerance
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Normal-layer windows that are on screen, from `CGWindowList`.
    static func onScreenWindows() -> [ListedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let number = entry[kCGWindowNumber as String] as? UInt32,
                let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { return nil }
            return ListedWindow(number: number, pid: pid, bounds: bounds)
        }
    }

    /// The frame of an Accessibility window (`AXPosition` and `AXSize`).
    static func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID(),
            AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
            AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}

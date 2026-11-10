import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LintelKit

/// Pure conversions between the two coordinate spaces and from `AXError` to the port's errors.
nonisolated enum WindowGeometry {
    /// AppKit frames have their origin at the bottom left of the primary display; the Accessibility API (and
    /// `WindowInfo.frame`) at its top left, y growing down.
    static func accessibilityFrame(of appKitFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: appKitFrame.minX, y: primaryHeight - appKitFrame.maxY, width: appKitFrame.width,
            height: appKitFrame.height)
    }

    /// `nil` means "not an error the port reports" (`.success`).
    static func clientError(for error: AXError) -> WindowClientError? {
        switch error {
        case .success: nil
        case .invalidUIElement: .windowGone
        case .cannotComplete: .timedOut
        case .apiDisabled: .notTrusted
        default: .refused
        }
    }

    /// What a read of an app's window list means, from the very call that was made (`AXWindowClient`): an app that
    /// does not answer within the messaging timeout is `unreachable` (its windows are unknown, not gone), an app that
    /// answers with an error (a process that is gone, no window attribute) simply has no windows, and `.success`
    /// carries the list. Pure, so the mapping is tested without Accessibility.
    enum ListOutcome: Equatable {
        case read
        case unreachable
        case noWindows
    }

    static func listOutcome(for error: AXError) -> ListOutcome {
        switch error {
        case .success: .read
        case .cannotComplete: .unreachable
        default: .noWindows
        }
    }

    /// The `CGDirectDisplayID` of a screen.
    @MainActor static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Every connected display, in the Accessibility coordinate space. The primary display is the first screen.
    @MainActor static func displays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return screens.compactMap { screen in
            guard let id = displayID(of: screen), let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            else { return nil }
            return DisplayInfo(
                id: id, uuid: CFUUIDCreateString(nil, uuid) as String,
                frame: accessibilityFrame(of: screen.frame, primaryHeight: primaryHeight),
                visibleFrame: accessibilityFrame(of: screen.visibleFrame, primaryHeight: primaryHeight),
                isMain: id == CGMainDisplayID())
        }
    }
}

/// When a process started, for validating stored window ids (a pid is reused after a reboot).
nonisolated enum ProcessStart {
    /// Seconds since 1970, or `nil` when the process does not exist or cannot be read.
    static func read(pid: Int32) -> TimeInterval? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }
}

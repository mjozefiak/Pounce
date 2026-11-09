import CoreGraphics
import Foundation
import LintelKit

/// A frame stored in `state.json`: plain numbers, so the file does not depend on how `CGRect` encodes.
struct FrameRecord: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// One window the engine parked: where it belongs, and which process it belonged to when it was parked. A
/// window id is trusted only while its pid, window number and process start time all match
/// (`StateStore.validated`). No title, no bundle id and no content is stored.
struct HiddenEntry: Codable, Hashable, Sendable {
    var windowID: WindowID
    /// Seconds since 1970 at which the owning process started.
    var processStart: Double
    /// The frame to restore.
    var homeFrame: FrameRecord
}

/// What `state.json` holds in version 1 (spec: Data Model). The tiling trees and zone placement arrive with
/// phases 2 and 3 as additive optional fields of `WorkspaceRecord`.
struct WindowsState: Equatable, Sendable {
    /// The windows of each workspace in join order.
    var order: [WorkspaceID: [WindowID]] = [:]
    /// Windows that are parked right now. Non-empty exactly while something is parked.
    var hidden: [HiddenEntry] = []

    static let empty = WindowsState()
}

/// The JSON shape of `state.json`.
struct StateFile: Codable {
    static let currentVersion = 1

    struct WorkspaceRecord: Codable, Equatable {
        var order: [WindowID]
    }

    var version: Int
    /// Keyed by the workspace number as a string (JSON object keys are strings).
    var workspaces: [String: WorkspaceRecord]
    var hidden: [HiddenEntry]

    init(version: Int = Self.currentVersion, state: WindowsState) {
        self.version = version
        self.workspaces = Dictionary(
            uniqueKeysWithValues: state.order.map { (String($0.key.rawValue), WorkspaceRecord(order: $0.value)) })
        self.hidden = state.hidden
    }

    /// The state this file describes; entries for workspaces outside 1 through 9 are dropped.
    var state: WindowsState {
        var order: [WorkspaceID: [WindowID]] = [:]
        for (key, record) in workspaces {
            guard let number = Int(key), let workspace = WorkspaceID(number) else { continue }
            order[workspace] = record.order
        }
        var seen = Set<WindowID>()
        let hidden = hidden.filter { seen.insert($0.windowID).inserted }
        return WindowsState(order: order, hidden: hidden)
    }
}

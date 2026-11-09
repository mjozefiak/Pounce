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

/// What `state.json` holds in version 1 (spec: Data Model). The tiling trees (phase 2) are an additive optional
/// field of `WorkspaceRecord`, so the file stays version 1 and an older build simply ignores them; zone
/// placement arrives with phase 3 the same way.
struct WindowsState: Equatable, Sendable {
    /// The windows of each workspace in join order.
    var order: [WorkspaceID: [WindowID]] = [:]
    /// Windows that are parked right now. Non-empty exactly while something is parked.
    var hidden: [HiddenEntry] = []
    /// The tiling tree of each workspace that has one (`workspaces[n].tiling`).
    var tiling: [WorkspaceID: TilingTree] = [:]

    static let empty = WindowsState()
}

/// The JSON shape of `state.json`.
struct StateFile: Codable {
    static let currentVersion = 1

    struct WorkspaceRecord: Codable, Equatable {
        var order: [WindowID]
        var tiling: TilingRecord?

        init(order: [WindowID], tiling: TilingRecord? = nil) {
            self.order = order
            self.tiling = tiling
        }

        private enum CodingKeys: String, CodingKey {
            case order
            case tiling
        }

        /// A tree that does not decode is dropped, not a reason to call the whole file corrupt: it only holds
        /// weights and shape, and the engine rebuilds it from the live windows.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            order = try container.decode([WindowID].self, forKey: .order)
            tiling = try? container.decodeIfPresent(TilingRecord.self, forKey: .tiling)
        }
    }

    var version: Int
    /// Keyed by the workspace number as a string (JSON object keys are strings).
    var workspaces: [String: WorkspaceRecord]
    var hidden: [HiddenEntry]

    init(version: Int = Self.currentVersion, state: WindowsState) {
        self.version = version
        var records: [String: WorkspaceRecord] = [:]
        for workspace in Set(state.order.keys).union(state.tiling.keys) {
            records[String(workspace.rawValue)] = WorkspaceRecord(
                order: state.order[workspace] ?? [], tiling: state.tiling[workspace].map(TilingRecord.init))
        }
        self.workspaces = records
        self.hidden = state.hidden
    }

    /// The state this file describes; entries for workspaces outside 1 through 9 are dropped.
    var state: WindowsState {
        var order: [WorkspaceID: [WindowID]] = [:]
        var tiling: [WorkspaceID: TilingTree] = [:]
        for (key, record) in workspaces {
            guard let number = Int(key), let workspace = WorkspaceID(number) else { continue }
            if !record.order.isEmpty || record.tiling == nil { order[workspace] = record.order }
            if let tree = record.tiling?.tree, !tree.isEmpty { tiling[workspace] = tree }
        }
        var seen = Set<WindowID>()
        let hidden = hidden.filter { seen.insert($0.windowID).inserted }
        return WindowsState(order: order, hidden: hidden, tiling: tiling)
    }
}

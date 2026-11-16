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

/// What `state.json` holds in version 1 (spec: Data Model). The state of each layout kind is an additive field of
/// `WorkspaceRecord` under the kind's name (`tiling`, `zones`, ...), so the file stays version 1 and an older
/// build simply ignores a kind it does not know. The store does not know what a kind's state looks like: it keeps
/// the JSON, and the strategy of the kind reads and writes it.
struct WindowsState: Equatable, Sendable {
    /// The windows of each workspace in join order.
    var order: [WorkspaceID: [WindowID]] = [:]
    /// Windows that are parked right now. Non-empty exactly while something is parked.
    var hidden: [HiddenEntry] = []
    /// The stored state of each layout kind of each workspace (`workspaces[n].<kind>`).
    var layouts: [WorkspaceID: [String: JSONValue]] = [:]

    static let empty = WindowsState()
}

/// The JSON shape of `state.json`.
struct StateFile: Codable {
    static let currentVersion = 1

    struct WorkspaceRecord: Codable, Equatable {
        var order: [WindowID]
        /// The JSON of each layout kind, by the kind's name.
        var layouts: [String: JSONValue]

        init(order: [WindowID], layouts: [String: JSONValue] = [:]) {
            self.order = order
            self.layouts = layouts
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
            static let order = Key(stringValue: "order")
        }

        /// Everything next to `order` is the state of a layout kind. A value that a strategy cannot read is
        /// dropped by the strategy, not a reason to call the whole file corrupt: it only holds shape and weights,
        /// and the engine rebuilds it from the live windows.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            order = try container.decode([WindowID].self, forKey: .order)
            layouts = [:]
            for key in container.allKeys where key.stringValue != Key.order.stringValue {
                if let json = try? container.decode(JSONValue.self, forKey: key) { layouts[key.stringValue] = json }
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(order, forKey: .order)
            for (name, json) in layouts.sorted(by: { $0.key < $1.key }) {
                try container.encode(json, forKey: Key(stringValue: name))
            }
        }
    }

    var version: Int
    /// Keyed by the workspace number as a string (JSON object keys are strings).
    var workspaces: [String: WorkspaceRecord]
    var hidden: [HiddenEntry]

    init(version: Int = Self.currentVersion, state: WindowsState) {
        self.version = version
        var records: [String: WorkspaceRecord] = [:]
        for workspace in Set(state.order.keys).union(state.layouts.keys) {
            records[String(workspace.rawValue)] = WorkspaceRecord(
                order: state.order[workspace] ?? [], layouts: state.layouts[workspace] ?? [:])
        }
        self.workspaces = records
        self.hidden = state.hidden
    }

    /// The state this file describes; entries for workspaces outside 1 through 9 are dropped.
    var state: WindowsState {
        var order: [WorkspaceID: [WindowID]] = [:]
        var layouts: [WorkspaceID: [String: JSONValue]] = [:]
        for (key, record) in workspaces {
            guard let number = Int(key), let workspace = WorkspaceID(number) else { continue }
            if !record.order.isEmpty || record.layouts.isEmpty { order[workspace] = record.order }
            if !record.layouts.isEmpty { layouts[workspace] = record.layouts }
        }
        var seen = Set<WindowID>()
        let hidden = hidden.filter { seen.insert($0.windowID).inserted }
        return WindowsState(order: order, hidden: hidden, layouts: layouts)
    }
}

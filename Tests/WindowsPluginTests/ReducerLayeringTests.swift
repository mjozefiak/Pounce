import Foundation
import Testing

@testable import WindowsPlugin

/// The reducer's parts form layers: a part never calls into a part below it, so there is no call web between them.
@Suite struct ReducerLayeringTests {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appending(path: "Sources/WindowsPlugin/Engine/Reducer/\(name).swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// What each part must not call: the members that live in a part below it.
    private let forbidden: [(file: String, calls: [String])] = [
        ("LayoutPlanner", ["request(", "reconcileParking(", "removeWindow(", "applied(", "perform("]),
        ("ReducerContext+Layout", ["reconcileParking(", "restore(", "removeWindow(", "windowMoved(", "applied("]),
        ("ReducerContext+Parking", ["removeWindow(", "windowMoved(", "releaseUnmanaged(", "applied(", "snapshot("]),
        ("ReducerContext+Windows", ["applied(", "perform(", "frameStarted("]),
        ("ReducerContext+Results", ["perform("]),
    ]

    @Test func noPartCallsIntoAPartBelowIt() throws {
        for (file, calls) in forbidden {
            let text = try source(file)
            for call in calls {
                #expect(!text.contains(call), "\(file) must not use \(call)")
            }
        }
    }
}

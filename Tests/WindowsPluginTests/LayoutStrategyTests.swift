import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The reducer knows no layout kind: it works through the registry.
@Suite struct LayoutStrategyTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }
    private let area = CGRect(x: 0, y: 25, width: 1920, height: 1055)

    /// A strategy of its own: every window gets the whole area.
    private struct FullScreenStrategy: LayoutStrategy {
        var kind: LayoutKind { .free }

        func arrange(_ input: LayoutInput) -> LayoutArrangement {
            LayoutArrangement(
                state: input.state, frames: Dictionary(uniqueKeysWithValues: input.windows.map { ($0, input.area) }),
                hints: input.hints)
        }
    }

    private func snapshot(_ windows: [WindowInfo]) -> EngineInput {
        .snapshot(
            windows: windows, displays: [FakeWindowClient.mainDisplay], focused: nil,
            processStarts: [100: 1_100], now: 1)
    }

    @Test func theReducerArrangesThroughWhatTheRegistryHoldsForTheKind() {
        var state = EngineState(workspaceCount: 2, displays: [FakeWindowClient.mainDisplay])
        state.config.layout = LayoutConfig(defaultKind: .free)
        let registry = LayoutRegistry([FullScreenStrategy()])
        let (next, effects) = EngineReducer.reduce(state, snapshot([makeWindow(1)]), strategies: registry)
        #expect(next.windows[id(1)] != nil)
        let frames = effects.compactMap { effect -> CGRect? in
            if case .setFrame(let request) = effect { request.frame } else { nil }
        }
        #expect(frames == [FakeWindowClient.mainDisplay.visibleFrame])
        // The standard registry arranges nothing for Free.
        let (_, standard) = EngineReducer.reduce(state, snapshot([makeWindow(1)]))
        #expect(!standard.contains { if case .setFrame = $0 { true } else { false } })
    }

    @Test func aKindThisBuildDoesNotKnowIsKeptAndWrittenBackUnchanged() throws {
        let json = #"{"version":1,"workspaces":{"1":{"order":[],"accordion":{"depth":3}}},"hidden":[]}"#
        let file = try JSONDecoder().decode(StateFile.self, from: Data(json.utf8))
        let stored = file.state.layouts
        #expect(stored[WorkspaceID(1)!]?["accordion"] != nil)
        let registry = LayoutRegistry.standard
        let loaded = registry.decode(stored)
        #expect(registry.encode(loaded) == stored)
        // And through the reducer: restored, then saved unchanged by an unrelated change.
        var state = EngineState(workspaceCount: 2, displays: [FakeWindowClient.mainDisplay])
        (state, _) = EngineReducer.reduce(state, .restoreLayouts(stored))
        #expect(state.layouts[WorkspaceID(1)!]?["accordion"] != nil)
    }

    @Test func aKnownKindThatDoesNotDecodeIsDroppedNotCorrupt() {
        let bad: [WorkspaceID: [String: JSONValue]] = [WorkspaceID(1)!: ["tiling": .string("nonsense")]]
        #expect(LayoutRegistry.standard.decode(bad).isEmpty)
    }
}

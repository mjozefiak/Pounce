import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The reducer knows no layout kind: it works through the registry.
@Suite(.timeLimit(.minutes(1))) struct LayoutStrategyTests {
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
        let json = #"{"version":1,"workspaces":{"1":{"order":[],"spiral":{"depth":3}}},"hidden":[]}"#
        let file = try JSONDecoder().decode(StateFile.self, from: Data(json.utf8))
        let stored = file.state.layouts
        #expect(stored[WorkspaceID(1)!]?["spiral"] != nil)
        let registry = LayoutRegistry.standard
        let loaded = registry.decode(stored)
        #expect(registry.encode(loaded) == stored)
        // And through the reducer: restored, then saved unchanged by an unrelated change.
        var state = EngineState(workspaceCount: 2, displays: [FakeWindowClient.mainDisplay])
        (state, _) = EngineReducer.reduce(state, .restoreLayouts(stored))
        #expect(state.layouts[WorkspaceID(1)!]?["spiral"] != nil)
    }

    @Test func aKnownKindThatDoesNotDecodeIsDroppedNotCorrupt() {
        let bad: [WorkspaceID: [String: JSONValue]] = [WorkspaceID(1)!: ["tiling": .string("nonsense")]]
        #expect(LayoutRegistry.standard.decode(bad).isEmpty)
    }
}

/// A fourth strategy, defined only here: it proves that a new kind is one type and one registry line, with no change
/// in the engine, the reducer, the state or the store.
@Suite(.timeLimit(.minutes(1))) struct ToyStrategyTests {
    struct ToyConfig: LayoutConfigValue, Equatable { var step: CGFloat }

    struct ToyState: LayoutStateValue, Equatable, Codable {
        var bumps = 0
        var isEmpty: Bool { bumps == 0 }
    }

    /// Lays the windows out left to right in steps from the configuration, and counts `toy.bump` commands.
    struct ToyStrategy: LayoutStrategy, SnapTargetProviding {
        var kind: LayoutKind { LayoutKind("toy") }

        var snapping: (any SnapTargetProviding)? { self }
        var settingRows: (any SettingRowProviding)? { self }

        /// One snap target whose command is the toy's own: snapping bumps the counter by 7.
        func snapTargets(_ input: LayoutInput) -> [DragDisplay] {
            let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            let zone = DragZone(
                displayKey: input.displayKey, zoneID: 1, number: 1, frame: frame,
                command: LayoutCommand("toy.bump", encoding: 7))
            return [DragDisplay(key: input.displayKey, area: input.area, zones: [zone])]
        }

        var displayName: String { "Toy" }

        /// The toy's own setting: how far apart the windows go. It has a global setting key of its own.
        var options: [LayoutOption] {
            [
                LayoutOption(
                    id: "toyStep", title: "Toy step", domain: .points(10...400), defaultValue: .int(111),
                    settingKey: "toy.step")
            ]
        }

        /// A command of the toy: bumps its counter. Defined here, listed by the plugin from the registry.
        var commands: [LayoutCommandSpec] {
            [
                LayoutCommandSpec(
                    id: "windows.toy.bump", title: LocalizedStringResource(stringLiteral: "Bump the Toy"),
                    symbolName: "star", command: .layout(LayoutCommand("toy.bump", encoding: 1)))
            ]
        }

        func summaryParts(_ resolved: ResolvedLayout) -> [String] {
            ["toy parts", "step \(resolved.int("toyStep") ?? -1)"]
        }

        func makeConfig(_ environment: LayoutEnvironment) -> AnyLayoutConfig? { AnyLayoutConfig(ToyConfig(step: 111)) }

        func arrange(_ input: LayoutInput) -> LayoutArrangement {
            let step = input.resolved.int("toyStep").map { CGFloat($0) } ?? input.config?.as(ToyConfig.self)?.step ?? 0
            var frames: [WindowID: CGRect] = [:]
            for (index, window) in input.windows.enumerated() {
                frames[window] = CGRect(x: CGFloat(index) * step, y: 0, width: 100, height: 100)
            }
            return LayoutArrangement(
                state: input.state ?? AnyLayoutState(ToyState()), frames: frames, hints: input.hints)
        }

        func perform(_ command: LayoutCommand, on window: WindowID, _ input: LayoutInput) -> LayoutEdit? {
            guard command.id == "toy.bump", var toy = input.state?.as(ToyState.self) else { return nil }
            toy.bumps += command.payload(as: Int.self) ?? 1
            return LayoutEdit(state: AnyLayoutState(toy), focus: nil, hints: input.hints)
        }

        func encode(_ state: AnyLayoutState) -> JSONValue? {
            state.as(ToyState.self).flatMap { JSONValue(encoding: $0) }
        }

        func decode(_ json: JSONValue) -> AnyLayoutState? {
            json.decoded(as: ToyState.self).map { AnyLayoutState($0) }
        }
    }

    private let toy = LayoutKind("toy")
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    private func registry() -> LayoutRegistry { LayoutRegistry([ToyStrategy(), FreeStrategy()]) }

    private func config(_ harness: WindowsHarness) -> EngineConfig {
        var config = EngineConfig()
        config.layout = LayoutConfig(defaultKind: toy)
        config.strategyConfigs = registry().configs(
            LayoutEnvironment(settings: WindowsSettings(harness.pluginSettings)))
        return config
    }

    @Test func theReducerArrangesPerformsPersistsAndRestoresAKindItNeverHeardOf() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        var state = EngineState(workspaceCount: 2, displays: [FakeWindowClient.mainDisplay])
        state.config = config(harness)
        let windows = [makeWindow(1), makeWindow(2)]
        let registry = registry()
        // Arrange: the frames come from the strategy and its own configuration.
        var effects: [EngineEffect]
        (state, effects) = EngineReducer.reduce(
            state,
            .snapshot(
                windows: windows, displays: [FakeWindowClient.mainDisplay], focused: id(1),
                processStarts: [100: 1_100], now: 1), strategies: registry)
        let frames = effects.compactMap { effect -> [CGFloat]? in
            if case .setFrame(let request) = effect { [request.frame.minX] } else { nil }
        }
        #expect(frames.flatMap { $0 }.sorted() == [0, 111])
        // Perform: a command only the toy knows, through the generic command.
        (state, _) = EngineReducer.reduce(
            state, .command(.layout(LayoutCommand("toy.bump", encoding: 3)), now: 2), strategies: registry)
        #expect(state.layouts[ws(1)]?["toy"]?.as(ToyState.self)?.bumps == 3)
        // Persist and restore: opaque JSON under the kind's name, and back.
        let stored = registry.encode(state.layouts)
        #expect(stored[ws(1)]?["toy"] != nil)
        var restored = EngineState(workspaceCount: 2, displays: [FakeWindowClient.mainDisplay])
        (restored, _) = EngineReducer.reduce(restored, .restoreLayouts(stored), strategies: registry)
        #expect(restored.layouts[ws(1)]?["toy"]?.as(ToyState.self)?.bumps == 3)
        // The standard registry does not know the kind: it keeps the state opaque and writes it back unchanged.
        let standard = LayoutRegistry.standard
        #expect(standard.encode(standard.decode(stored)) == stored)
    }

    @Test func aWholeEngineKeepsTheToysStateAcrossARestart() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        func engine(_ client: FakeWindowClient) -> (WindowEngine, StateStore) {
            let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
            let engine = makeEngine(
                client: client, store: store, clock: VirtualClock(), workspaceCount: 2, config: config(harness),
                tick: .milliseconds(5), strategies: registry())
            return (engine, store)
        }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        client.setFocused(id(1))
        let (first, _) = engine(client)
        await first.start()
        await first.send(.layout(LayoutCommand("toy.bump", encoding: 5)))
        await first.stop()
        let (second, _) = engine(client)
        await second.start()
        #expect(await second.snapshot.layouts[ws(1)]?["toy"]?.as(ToyState.self)?.bumps == 5)
        await second.stop()
    }

    /// A strategy under a name the stored workspace record uses for something else.
    struct OrderStrategy: LayoutStrategy {
        var kind: LayoutKind { LayoutKind("order") }
        func arrange(_ input: LayoutInput) -> LayoutArrangement {
            LayoutArrangement(state: nil, frames: [:], hints: input.hints)
        }
    }

    @Test func aKindNamedLikeAStateKeyIsLeftOutAndTheCycleNeverTraps() {
        let registry = LayoutRegistry([OrderStrategy(), ToyStrategy(), ToyStrategy()])
        #expect(registry.kinds == [toy])
        #expect(!registry.contains(LayoutKind("order")))
        // "default" is the picker's "use the default", never a kind.
        struct DefaultStrategy: LayoutStrategy {
            var kind: LayoutKind { LayoutKind("default") }
            func arrange(_ input: LayoutInput) -> LayoutArrangement {
                LayoutArrangement(state: nil, frames: [:], hints: input.hints)
            }
        }
        #expect(LayoutRegistry([DefaultStrategy()]).kinds.isEmpty)
        // The cycle wraps, falls back for a kind that is not registered, and an empty registry still answers.
        #expect(registry.kind(after: toy) == toy)
        #expect(registry.kind(after: .zones) == toy)
        #expect(LayoutRegistry([]).kind(after: .zones) == .free)
    }

    @MainActor @Test func theToyIsReachableThroughThePaneTheSettingsAndTheToggleCommand() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let registry = LayoutRegistry([TilingStrategy(), ZonesStrategy(), FreeStrategy(), ToyStrategy()])
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter(), layouts: registry)
        try await plugin.activate()
        let runtime = try #require(plugin.runtime)
        await runtime.settle()
        // The pane offers the kind by its own name, summarises it with its own words and stores it.
        let model = plugin.paneModel
        #expect(model.selectableKinds == [.tiling, .zones, .free, toy])
        #expect(model.kindName(toy) == "Toy")
        model.setDefaultKind(toy)
        await model.actions.waitUntilEmpty()
        #expect(model.workspaceSummaries.first?.detail == "Toy · toy parts · step 111")
        #expect(WindowsSettings(harness.pluginSettings).defaultKind(in: registry) == toy)
        // The runtime arranges with the strategy's own configuration, and *Toggle layout* cycles through it.
        await runtime.settle()
        #expect(client.frame(of: id(2))?.minX == 111)
        await runtime.layoutCommands.toggleLayout()
        await runtime.settle()
        let overrides = WindowsSettings(harness.pluginSettings).workspaceOverrides(in: registry)
        #expect(overrides.byWorkspace[ws(1)]?.kind == .tiling)
        await plugin.deactivate()
    }

    @MainActor @Test func aFourthKindsOptionCommandAndRowReachThePaneTheSettingsTheEngineAndTheCatalogue() async throws
    {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let registry = LayoutRegistry([TilingStrategy(), ZonesStrategy(), FreeStrategy(), ToyStrategy()])
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
        client.setFocused(id(1))
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter(), layouts: registry)
        try await plugin.activate()
        let runtime = try #require(plugin.runtime)
        let model = plugin.paneModel
        model.setDefaultKind(toy)
        await model.actions.waitUntilEmpty()
        await runtime.settle()

        // The command catalogue lists the toy's command, with the title and symbol it declared.
        let commands = plugin.commands
        let bump = try #require(commands.first { $0.id == "windows.toy.bump" })
        #expect(bump.symbolName == "star")
        // ... and running it reaches the toy's `perform` through the generic engine command.
        await bump.run()
        await runtime.settle()
        #expect(await runtime.engine.snapshot.layouts[ws(1)]?["toy"]?.as(ToyState.self)?.bumps == 1)
        // The commands of the kinds that are not registered are not offered.
        let standard = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        #expect(!standard.commands.contains { $0.id == "windows.toy.bump" })

        // The pane model offers the option as a global row, stores it under the setting key it declared, and the
        // engine arranges with it.
        let option = try #require(model.globalOptionRows.first { $0.id == "toyStep" })
        model.setGlobalValue(.int(250), of: option)
        await model.actions.waitUntilEmpty()
        await runtime.settle()
        #expect(harness.pluginSettings.integer("toy.step", default: 0) == 250)
        #expect(client.frame(of: id(2))?.minX == 250)
        #expect(model.workspaceSummaries.first?.detail == "Toy · toy parts · step 250")

        // A workspace override of the option is stored flat next to the kind and wins for that workspace.
        model.setOverrideOption(option, to: .int(300), for: ws(1))
        await model.actions.waitUntilEmpty()
        await runtime.settle()
        #expect(client.frame(of: id(2))?.minX == 300)
        #expect(model.options(of: ws(1)).map(\.id) == ["toyStep"])
        #expect(harness.pluginSettings.string(WindowsSettings.Key.workspaces)?.contains("\"toyStep\":300") == true)
        // A value out of range is made valid, one of the wrong type is refused.
        model.setOverrideOption(option, to: .int(9_000), for: ws(1))
        #expect(model.override(for: ws(1)).options["toyStep"] == .int(400))
        model.setOverrideOption(option, to: .string("wide"), for: ws(1))
        #expect(model.override(for: ws(1)).options["toyStep"] == nil)

        // Snapping is generic: the target the toy offers carries the toy's own command, which the plugin sends.
        let targets = await runtime.engine.dragDisplays(for: id(1))
        let zone = try #require(targets.first?.zones.first)
        await runtime.snap(id(1), to: zone)
        await runtime.settle()
        #expect(await runtime.engine.snapshot.layouts[ws(1)]?["toy"]?.as(ToyState.self)?.bumps == 8)

        // A command of a kind that takes an id the plugin owns is left out of the catalogue.
        struct Greedy: LayoutStrategy {
            var kind: LayoutKind { LayoutKind("greedy") }
            var commands: [LayoutCommandSpec] {
                [
                    LayoutCommandSpec(
                        id: "windows.focus.left", title: LocalizedStringResource(stringLiteral: "x"), symbolName: "x",
                        command: .toggleFloating)
                ]
            }
            func arrange(_ input: LayoutInput) -> LayoutArrangement {
                LayoutArrangement(state: nil, frames: [:], hints: input.hints)
            }
        }
        #expect(LayoutRegistry([Greedy()]).commandSpecs.isEmpty)

        // The kind's own settings rows are drawn by the pane from the strategy.
        #expect(model.strategySettingRows.map(\.id).suffix(1) == ["toy.row"])
        #expect(model.strategySettingRows.count == 3)
        await plugin.deactivate()
    }

    @Test func aStrategyWhoseOptionIdRepeatsAnEarlierOneIsLeftOut() {
        struct Clash: LayoutStrategy {
            var kind: LayoutKind { LayoutKind("clash") }
            var options: [LayoutOption] {
                [LayoutOption(id: "toyStep", title: "x", domain: .points(0...1), defaultValue: .int(0))]
            }
            func arrange(_ input: LayoutInput) -> LayoutArrangement {
                LayoutArrangement(state: nil, frames: [:], hints: input.hints)
            }
        }
        struct Kindly: LayoutStrategy {
            var kind: LayoutKind { LayoutKind("kindly") }
            var options: [LayoutOption] {
                [LayoutOption(id: "kind", title: "x", domain: .points(0...1), defaultValue: .int(0))]
            }
            func arrange(_ input: LayoutInput) -> LayoutArrangement {
                LayoutArrangement(state: nil, frames: [:], hints: input.hints)
            }
        }
        let registry = LayoutRegistry([ToyStrategy(), Clash(), Kindly()])
        #expect(registry.kinds == [toy])
    }
}

extension ToyStrategyTests.ToyStrategy: SettingRowProviding {
    func settingRows(_ context: LayoutSettingsContext) -> [LayoutSettingRow] {
        [
            LayoutSettingRow(
                id: "toy.row", title: "Toy row", help: nil, choices: { [.init(id: "a", title: "A")] },
                selection: { "a" }, select: { _ in })
        ]
    }
}

import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// A third search feature, so a move can land above, below or between two rows.
final class ThirdFeaturePlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "third", displayName: "Third", symbolName: "3.circle", order: 4)

    init(context: PluginContext) {}

    var searchSources: [any SearchSource] { [InstantSource(id: "third.source")] }
}

/// Settings → Features → Result order (step 4.1 review fix): the Move Up and Move Down buttons each row has for the
/// keyboard, and drag and drop, both through `SectionOrderControls`.
@MainActor
@Suite(.serialized) struct ResultOrderTests {
    let env: TestEnvironment

    init() throws {
        env = try TestEnvironment()
    }

    /// Plain, Other and Third in their manifest order.
    private func controls() async -> SectionOrderControls {
        let host = env.makeHost([PlainFeaturePlugin.self, OtherFeaturePlugin.self, ThirdFeaturePlugin.self])
        await host.start()
        return SectionOrderControls(host: host, settings: AppSettings(store: env.settings))
    }

    private func ids(_ order: SectionOrderControls) -> [String] {
        order.ordered.map(\.manifest.id.rawValue)
    }

    // The row buttons (the same calls as the context menu and the VoiceOver actions).

    @Test func moveUpAndMoveDownSaveTheWholeOrder() async {
        defer { env.tearDown() }
        let order = await controls()
        #expect(ids(order) == ["plain", "other", "third"])
        order.move("third", by: -1)
        #expect(ids(order) == ["plain", "third", "other"])
        #expect(order.settings.sectionOrder == ["plain", "third", "other"])
        order.move("plain", by: 1)
        #expect(ids(order) == ["third", "plain", "other"])
    }

    @Test func theEndsDoNotMove() async {
        defer { env.tearDown() }
        let order = await controls()
        order.move("plain", by: -1)
        order.move("third", by: 1)
        #expect(ids(order) == ["plain", "other", "third"])
    }

    @Test func theRowsButtonsFollowThePosition() async {
        defer { env.tearDown() }
        let order = await controls()
        let rows = order.ordered.enumerated().map { index, entry in
            ResultOrderRow(order: order, entry: entry, index: index, count: 3) { _ in true }
        }
        #expect(rows.map(\.canMoveUp) == [false, true, true])
        #expect(rows.map(\.canMoveDown) == [true, true, false])
    }

    // Drag and drop: `move(_:to:)` with the index of the row the item was dropped on.

    @Test func droppingOnARowAboveTakesItsPlace() async {
        defer { env.tearDown() }
        let order = await controls()
        order.move("third", to: 0)
        #expect(ids(order) == ["third", "plain", "other"])
        #expect(order.settings.sectionOrder == ["third", "plain", "other"])
    }

    @Test func droppingOnARowBelowTakesItsPlace() async {
        defer { env.tearDown() }
        let order = await controls()
        order.move("plain", to: 2)
        #expect(ids(order) == ["other", "third", "plain"])
        order.move("other", to: 1)
        #expect(ids(order) == ["third", "other", "plain"])
    }

    @Test func droppingOntoItselfKeepsTheOrder() async {
        defer { env.tearDown() }
        let order = await controls()
        order.move("other", to: 1)
        #expect(ids(order) == ["plain", "other", "third"])
    }

    @Test func anIndexOutOfRangeIsClamped() async {
        defer { env.tearDown() }
        let order = await controls()
        order.move("plain", to: 9)
        #expect(ids(order) == ["other", "third", "plain"])
        order.move("plain", to: -3)
        #expect(ids(order) == ["plain", "other", "third"])
    }

    @Test func anUnknownIDChangesNothing() async {
        defer { env.tearDown() }
        let order = await controls()
        order.move("missing", to: 0)
        #expect(ids(order) == ["plain", "other", "third"])
        #expect(order.settings.sectionOrder.isEmpty)
    }
}

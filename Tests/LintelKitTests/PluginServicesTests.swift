import Synchronization
import Testing

@testable import LintelKit

/// `PluginServices`: typed keys, scoped per plugin, safe to nest, torn down on request.
@Suite struct PluginServicesTests {
    final class Counter: Sendable {
        let made = Mutex(0)
        let tornDown = Mutex(0)
    }

    private static let counter = Counter()

    enum NumberKey: PluginServiceKey {
        static func make(context: PluginContext) -> Int { 7 }
    }

    enum TextKey: PluginServiceKey {
        static func make(context: PluginContext) -> String { "text" }
    }

    /// Asks for another key while it is being made: no lock may be held meanwhile.
    enum NestedKey: PluginServiceKey {
        static func make(context: PluginContext) -> String {
            "nested \(context.services.value(NumberKey.self, for: context))"
        }
    }

    final class Tracked: Sendable {
        let id = Mutex(0)
    }

    enum TrackedKey: PluginServiceKey {
        static func make(context: PluginContext) -> Tracked {
            counter.made.withLock { $0 += 1 }
            return Tracked()
        }

        static func teardown(_ value: Tracked) { counter.tornDown.withLock { $0 += 1 } }
    }

    @Test func eachKeyHasItsOwnTypeAndTheSameValueComesBack() {
        let services = PluginServices()
        let context = TestContext.make(services: services)
        #expect(services.value(NumberKey.self, for: context) == 7)
        #expect(services.value(TextKey.self, for: context) == "text")
        let first = services.value(TrackedKey.self, for: context)
        #expect(services.value(TrackedKey.self, for: context) === first)
    }

    @Test func aValueBelongsToTheAskingPluginOnly() {
        let services = PluginServices()
        let one = TestContext.make(pluginID: "one", services: services)
        let two = TestContext.make(pluginID: "two", services: services)
        let first = services.value(TrackedKey.self, for: one)
        let second = services.value(TrackedKey.self, for: two)
        #expect(first !== second)
        #expect(services.holds(TrackedKey.self, pluginID: "one"))
        services.teardown(pluginID: "one")
        #expect(!services.holds(TrackedKey.self, pluginID: "one"))
        #expect(services.holds(TrackedKey.self, pluginID: "two"))
    }

    @Test func aKeyMayAskForAnotherKeyWhileItIsMade() {
        let services = PluginServices()
        let context = TestContext.make(services: services)
        #expect(services.value(NestedKey.self, for: context) == "nested 7")
    }

    @Test func tearDownCallsTheKeysHookAndForgetsTheValue() {
        let services = PluginServices()
        let context = TestContext.make(pluginID: "teardown", services: services)
        let before = Self.counter.tornDown.withLock { $0 }
        _ = services.value(TrackedKey.self, for: context)
        services.teardown(pluginID: "teardown")
        #expect(Self.counter.tornDown.withLock { $0 } == before + 1)
        // A later ask makes a new value.
        let again = services.value(TrackedKey.self, for: context)
        #expect(services.holds(TrackedKey.self, pluginID: "teardown"))
        _ = again
    }

    @Test func twoInstancesOfServicesShareNothing() {
        let one = PluginServices()
        let two = PluginServices()
        let first = one.value(TrackedKey.self, for: TestContext.make(services: one))
        let second = two.value(TrackedKey.self, for: TestContext.make(services: two))
        #expect(first !== second)
    }
}

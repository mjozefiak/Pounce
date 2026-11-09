import Synchronization
import Testing

@testable import LintelKit

/// `PluginServices`: typed keys, scoped per plugin, safe to nest, torn down on request.
@Suite struct PluginServicesTests {
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

    /// A value that knows whether its key's teardown ran on it (no counters shared between tests).
    final class Tracked: Sendable {
        let tornDown = Mutex(false)
    }

    enum TrackedKey: PluginServiceKey {
        static func make(context: PluginContext) -> Tracked { Tracked() }

        static func teardown(_ value: Tracked) { value.tornDown.withLock { $0 = true } }
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
        let value = services.value(TrackedKey.self, for: context)
        #expect(!value.tornDown.withLock { $0 })
        services.teardown(pluginID: "teardown")
        #expect(value.tornDown.withLock { $0 })
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

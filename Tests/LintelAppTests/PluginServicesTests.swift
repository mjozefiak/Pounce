import LintelKit
import Synchronization
import Testing

@testable import LintelApp

/// `AppPluginServices` (the host's implementation of the `PluginServices` port): typed keys, scoped per plugin, safe
/// to nest, torn down on request.
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

    private func manifest(_ id: PluginID) -> PluginManifest {
        PluginManifest(id: id, displayName: "Test", symbolName: "circle", order: 1)
    }

    @Test func eachKeyHasItsOwnTypeAndTheSameValueComesBack() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let services = env.environment.services
        let context = env.environment.makeContext(for: manifest("one"))
        #expect(services.value(NumberKey.self, for: context) == 7)
        #expect(services.value(TextKey.self, for: context) == "text")
        let first = services.value(TrackedKey.self, for: context)
        #expect(services.value(TrackedKey.self, for: context) === first)
    }

    @Test func aValueBelongsToTheAskingPluginOnly() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let services = env.environment.services
        let one = env.environment.makeContext(for: manifest("one"))
        let two = env.environment.makeContext(for: manifest("two"))
        let first = services.value(TrackedKey.self, for: one)
        let second = services.value(TrackedKey.self, for: two)
        #expect(first !== second)
        #expect(services.holds(TrackedKey.self, pluginID: "one"))
        services.teardown(pluginID: "one")
        #expect(!services.holds(TrackedKey.self, pluginID: "one"))
        #expect(services.holds(TrackedKey.self, pluginID: "two"))
    }

    @Test func theContextNamesItsPluginExplicitly() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        #expect(env.environment.makeContext(for: manifest("named")).pluginID == "named")
    }

    @Test func aKeyMayAskForAnotherKeyWhileItIsMade() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let context = env.environment.makeContext(for: manifest("nested"))
        #expect(env.environment.services.value(NestedKey.self, for: context) == "nested 7")
    }

    @Test func tearDownCallsTheKeysHookAndForgetsTheValue() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let services = env.environment.services
        let context = env.environment.makeContext(for: manifest("teardown"))
        let value = services.value(TrackedKey.self, for: context)
        #expect(!value.tornDown.withLock { $0 })
        services.teardown(pluginID: "teardown")
        #expect(value.tornDown.withLock { $0 })
        // A later ask makes a new value.
        let again = services.value(TrackedKey.self, for: context)
        #expect(again !== value)
        #expect(services.holds(TrackedKey.self, pluginID: "teardown"))
    }

    @Test func twoInstancesOfServicesShareNothing() throws {
        let one = try TestEnvironment()
        let two = try TestEnvironment()
        defer {
            one.tearDown()
            two.tearDown()
        }
        let first = one.environment.services.value(
            TrackedKey.self, for: one.environment.makeContext(for: manifest("same")))
        let second = two.environment.services.value(
            TrackedKey.self, for: two.environment.makeContext(for: manifest("same")))
        #expect(first !== second)
    }

    @Test func aContextWithoutAHostKeepsNothing() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let context = env.environment.makeContext(for: manifest("unshared"))
        let services = UnsharedPluginServices()
        #expect(services.value(TrackedKey.self, for: context) !== services.value(TrackedKey.self, for: context))
    }
}

/// A typed, per-plugin service: something a plugin needs one shared instance of for the life of the app, which also
/// has to be reachable from code that has a `PluginContext` but no plugin instance (`recoverAtLaunch` is the case).
///
/// `make(context:)` runs the first time the plugin asks for the value. It should be cheap and free of side effects:
/// if two threads ask at the same moment both may run it and the first value stored wins (the other is torn
/// down at once). It may ask for other keys through the same services; it must not ask for its own key.
public protocol PluginServiceKey {
    associatedtype Value: Sendable
    static func make(context: PluginContext) -> Value
    /// Called when the host tears the plugin's services down (the app quits), or for a value that lost a race.
    static func teardown(_ value: Value)
}

extension PluginServiceKey {
    public static func teardown(_ value: Value) {}
}

/// The port through which a plugin reaches the values its app instance shares (`PluginContext.services`). The host
/// implements it (`AppPluginServices` in `LintelApp`: one instance per app, so one value per plugin and key for
/// the whole app); this target only declares it, like every other port. A value belongs to the plugin whose id is
/// given and is not reachable through another plugin's id.
///
/// A context built without a host (tests, previews) gets `UnsharedPluginServices`: every ask makes a new value, so
/// a plugin that needs one shared instance (like `WindowsPlugin`'s journal owner) is given the host's services, or
/// a test's own implementation, explicitly.
public protocol PluginServices: Sendable {
    /// The value of `key` for the plugin `pluginID`, made on first use with `context`.
    func value<Key: PluginServiceKey>(_ key: Key.Type, pluginID: PluginID, context: PluginContext) -> Key.Value

    /// Tears down every value of the plugin and forgets it. Host only (the app quits).
    func teardown(pluginID: PluginID)
}

extension PluginServices {
    /// The value of `key` for the plugin the context belongs to (`PluginContext.pluginID`).
    public func value<Key: PluginServiceKey>(_ key: Key.Type, for context: PluginContext) -> Key.Value {
        value(key, pluginID: context.pluginID, context: context)
    }

    public func teardown(pluginID: PluginID) {}
}

/// The default of a context without a host: nothing is kept, every ask makes a new value.
public struct UnsharedPluginServices: PluginServices {
    public init() {}

    public func value<Key: PluginServiceKey>(_ key: Key.Type, pluginID: PluginID, context: PluginContext) -> Key.Value {
        Key.make(context: context)
    }
}

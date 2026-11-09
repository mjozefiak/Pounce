import Synchronization

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

/// The services of the plugins of one app instance, owned by the host and handed to every plugin through its
/// `PluginContext`. A value belongs to the plugin whose context asked for it and is only reachable through a context
/// of that plugin, so one plugin cannot read another's. The host tears a plugin's values down explicitly
/// (`teardown(pluginID:)`); nothing lives in a process-wide global, and tests make their own instance.
public final class PluginServices: Sendable {
    private struct Slot {
        var value: any Sendable
        var teardown: @Sendable () -> Void
    }

    private struct Address: Hashable {
        var plugin: PluginID
        var key: ObjectIdentifier
    }

    private let slots = Mutex<[Address: Slot]>([:])

    public init() {}

    /// The plugin's value for `key`, made on first use. The lock is not held while `make` runs, so a `make` that
    /// asks for other keys cannot deadlock.
    public func value<Key: PluginServiceKey>(_ key: Key.Type, for context: PluginContext) -> Key.Value {
        let address = Address(plugin: context.settings.pluginID, key: ObjectIdentifier(key))
        if let existing = slots.withLock({ $0[address] })?.value as? Key.Value { return existing }
        let made = Key.make(context: context)
        let kept = slots.withLock { slots -> Key.Value? in
            if let existing = slots[address]?.value as? Key.Value { return existing }
            slots[address] = Slot(value: made, teardown: { Key.teardown(made) })
            return nil
        }
        if let kept {
            Key.teardown(made)
            return kept
        }
        return made
    }

    /// Tears down every value of the plugin and forgets it.
    public func teardown(pluginID: PluginID) {
        let doomed = slots.withLock { slots -> [Slot] in
            let addresses = slots.keys.filter { $0.plugin == pluginID }
            return addresses.compactMap { slots.removeValue(forKey: $0) }
        }
        for slot in doomed { slot.teardown() }
    }

    /// Whether the plugin holds a value for `key` (tests).
    public func holds<Key: PluginServiceKey>(_ key: Key.Type, pluginID: PluginID) -> Bool {
        slots.withLock { $0[Address(plugin: pluginID, key: ObjectIdentifier(key))] != nil }
    }
}

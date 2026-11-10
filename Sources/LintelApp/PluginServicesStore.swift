import LintelKit
import Synchronization

/// The host's `PluginServices`: one instance per app, handed to every plugin through its `PluginContext`. A value
/// belongs to the plugin whose id asked for it; the host tears a plugin's values down explicitly
/// (`teardown(pluginID:)`). Nothing lives in a process-wide global, and tests make their own instance.
nonisolated final class AppPluginServices: PluginServices {
    private struct Slot {
        var value: any Sendable
        var teardown: @Sendable () -> Void
    }

    private struct Address: Hashable {
        var plugin: PluginID
        var key: ObjectIdentifier
    }

    private let slots = Mutex<[Address: Slot]>([:])

    init() {}

    /// The plugin's value for `key`, made on first use. The lock is not held while `make` runs, so a `make` that
    /// asks for other keys cannot deadlock.
    func value<Key: PluginServiceKey>(_ key: Key.Type, pluginID: PluginID, context: PluginContext) -> Key.Value {
        let address = Address(plugin: pluginID, key: ObjectIdentifier(key))
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

    func teardown(pluginID: PluginID) {
        let doomed = slots.withLock { slots -> [Slot] in
            let addresses = slots.keys.filter { $0.plugin == pluginID }
            return addresses.compactMap { slots.removeValue(forKey: $0) }
        }
        for slot in doomed { slot.teardown() }
    }

    /// Whether the plugin holds a value for `key`.
    func holds<Key: PluginServiceKey>(_ key: Key.Type, pluginID: PluginID) -> Bool {
        slots.withLock { $0[Address(plugin: pluginID, key: ObjectIdentifier(key))] != nil }
    }
}

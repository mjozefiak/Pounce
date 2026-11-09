import Synchronization

/// Values that the plugins of one app instance share, owned by the host and handed to every plugin through its
/// `PluginContext`, so nothing has to live in a process-wide global. A value is made on first request and the same
/// one is returned afterwards for the same key; the code that recovers at launch (which has a context but no
/// plugin instance) and the plugin that runs later reach the same one. Tests make their own.
public final class PluginServices: Sendable {
    private let values = Mutex<[String: any Sendable]>([:])

    public init() {}

    /// The value stored under `key`, made by `make` the first time. Use a key that names the plugin.
    public func shared<Value: Sendable>(_ key: String, make: () -> Value) -> Value {
        values.withLock { values in
            if let existing = values[key] as? Value { return existing }
            let created = make()
            values[key] = created
            return created
        }
    }
}

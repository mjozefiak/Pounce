import CoreFoundation
import Foundation
import PounceKit
import Synchronization

/// Settings in a `UserDefaults` domain (`UserDefaults.standard`, the `app.pounce.Pounce` domain, in
/// the app).
///
/// `@unchecked Sendable` is safe here: Apple documents `UserDefaults` as thread-safe, the reference is
/// immutable (`let`), and this type keeps no other state.
nonisolated final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func value(forKey key: String) -> SettingValue? {
        Self.settingValue(from: defaults.object(forKey: key))
    }

    func setValue(_ value: SettingValue?, forKey key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(Self.propertyListObject(for: value), forKey: key)
    }

    /// Maps a stored property-list object to a setting. Booleans are stored as `CFBoolean`; any other
    /// number reads as an integer. Types a setting cannot hold read as `nil`.
    static func settingValue(from object: Any?) -> SettingValue? {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .integer(number.intValue)
        case let string as String:
            return .string(string)
        case let strings as [String]:
            return .stringArray(strings)
        default:
            return nil
        }
    }

    static func propertyListObject(for value: SettingValue) -> Any {
        switch value {
        case .bool(let bool): bool
        case .integer(let integer): integer
        case .string(let string): string
        case .stringArray(let strings): strings
        }
    }
}

/// Settings that live only in memory. Used by tests and QA mode, so they never write a defaults
/// domain (a `UserDefaults` suite leaves its plist in `~/Library/Preferences` even after
/// `removePersistentDomain`).
nonisolated final class InMemorySettingsStore: SettingsStore {
    private let values: Mutex<[String: SettingValue]>

    init(_ initial: [String: SettingValue] = [:]) {
        values = Mutex(initial)
    }

    func value(forKey key: String) -> SettingValue? {
        values.withLock { $0[key] }
    }

    func setValue(_ value: SettingValue?, forKey key: String) {
        values.withLock { $0[key] = value }
    }
}

import Foundation
import Observation
import PounceKit
import os

/// Stores and registers global shortcuts. The live implementation is KeyboardShortcuts; QA mode and
/// tests use implementations that never register anything with the system.
protocol HotkeyRegistrar: AnyObject {
    func shortcut(for name: HotkeyName) -> HotkeyShortcut?
    func setShortcut(_ shortcut: HotkeyShortcut?, for name: HotkeyName)
    /// Calls `action` on every key-down of the shortcut until `removeHandler(for:)`.
    func setHandler(for name: HotkeyName, _ action: @escaping @MainActor () -> Void)
    func removeHandler(for name: HotkeyName)
}

/// A shortcut's storage name. KeyboardShortcuts keeps it under `KeyboardShortcuts_<rawValue>`, and the
/// raw value must not contain a dot.
struct HotkeyName: Hashable, Sendable {
    let rawValue: String

    static let main = HotkeyName(rawValue: "mainHotkey")

    /// `command_<id>` with every character outside `[A-Za-z0-9_]` replaced by `_`.
    static func command(_ id: String) -> HotkeyName {
        let safe = id.unicodeScalars.map { scalar -> String in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_") ? String(scalar) : "_"
        }
        return HotkeyName(rawValue: "command_" + safe.joined())
    }
}

/// The main shortcut (open the panel) and the plugins' command shortcuts.
///
/// Q10: the default is Command-Space, or Control-Option-Space while Spotlight holds Command-Space. The
/// default is re-evaluated at launch and whenever Settings opens, so it moves to Command-Space once the
/// user frees it, unless the user recorded a shortcut themselves (`app.hotkey.userDefined`).
@Observable
final class HotkeyService {
    @ObservationIgnored private let registrar: any HotkeyRegistrar
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let readOccupied: () -> Set<HotkeyShortcut>
    @ObservationIgnored private var commandNames: Set<HotkeyName> = []
    @ObservationIgnored private let logger = Logger(subsystem: "app.pounce", category: "hotkeys")

    /// The current main shortcut, for menus and settings.
    private(set) var mainShortcut: HotkeyShortcut?
    /// Whether Spotlight (or another symbolic hotkey) holds Command-Space right now.
    private(set) var spotlightHoldsCommandSpace = false

    init(
        registrar: any HotkeyRegistrar,
        settings: any SettingsStore,
        readOccupied: @escaping () -> Set<HotkeyShortcut> = {
            SymbolicHotkeys.occupiedShortcuts(SymbolicHotkeys.readSystem())
        }
    ) {
        self.registrar = registrar
        self.settings = settings
        self.readOccupied = readOccupied
    }

    var isUserDefined: Bool {
        guard case .bool(let value) = settings.value(forKey: SettingsKeys.hotkeyUserDefined) else { return false }
        return value
    }

    /// The shortcut Pounce suggests right now.
    var defaultShortcut: HotkeyShortcut {
        ShortcutPolicy.defaultShortcut(occupied: readOccupied())
    }

    /// Applies the default when the user has not chosen a shortcut, and starts listening.
    func start(onMainShortcut action: @escaping @MainActor () -> Void) {
        refreshDefault()
        registrar.setHandler(for: .main, action)
    }

    /// Re-reads the symbolic hotkeys and moves the main shortcut to the current default unless the user
    /// chose one.
    func refreshDefault() {
        let occupied = readOccupied()
        spotlightHoldsCommandSpace = occupied.contains(.commandSpace)
        let current = registrar.shortcut(for: .main)
        let resolved = ShortcutPolicy.resolve(current: current, userDefined: isUserDefined, occupied: occupied)
        if resolved != current {
            registrar.setShortcut(resolved, for: .main)
            logger.info("Main shortcut set to the default \(resolved?.displayString ?? "none", privacy: .public)")
        }
        mainShortcut = registrar.shortcut(for: .main)
    }

    /// The user recorded (or cleared) the main shortcut in a recorder; it now always wins.
    func userRecordedMainShortcut() {
        settings.setValue(.bool(true), forKey: SettingsKeys.hotkeyUserDefined)
        mainShortcut = registrar.shortcut(for: .main)
    }

    /// Goes back to the automatic default (the onboarding step's "Skip").
    func resetToDefault() {
        settings.setValue(nil, forKey: SettingsKeys.hotkeyUserDefined)
        refreshDefault()
    }

    /// Registers the shortcuts of active plugins' commands and drops those of commands that are gone. A
    /// command's default shortcut is applied once; after that the stored value (possibly none) is kept.
    func syncCommands(_ commands: [PluginCommand], perform: @escaping @MainActor (PluginCommand) -> Void) {
        var applied = Set(stringArray(SettingsKeys.commandShortcutDefaultsApplied))
        var active = Set<HotkeyName>()
        for command in commands {
            let name = HotkeyName.command(command.id)
            active.insert(name)
            if !applied.contains(command.id) {
                if registrar.shortcut(for: name) == nil,
                    let shortcut = command.defaultShortcut.flatMap(HotkeyShortcut.init)
                {
                    registrar.setShortcut(shortcut, for: name)
                }
                applied.insert(command.id)
            }
            registrar.setHandler(for: name) { perform(command) }
        }
        for name in commandNames.subtracting(active) {
            registrar.removeHandler(for: name)
        }
        commandNames = active
        settings.setValue(.stringArray(applied.sorted()), forKey: SettingsKeys.commandShortcutDefaultsApplied)
    }

    func shortcut(for name: HotkeyName) -> HotkeyShortcut? {
        registrar.shortcut(for: name)
    }

    private func stringArray(_ key: String) -> [String] {
        guard case .stringArray(let values) = settings.value(forKey: key) else { return [] }
        return values
    }
}

/// Keeps shortcuts in memory and never registers anything. Tests use it directly; QA mode uses it so a
/// QA run never takes the tester's shortcuts.
final class InMemoryHotkeyRegistrar: HotkeyRegistrar {
    private(set) var shortcuts: [HotkeyName: HotkeyShortcut] = [:]
    private(set) var handlers: [HotkeyName: @MainActor () -> Void] = [:]

    func shortcut(for name: HotkeyName) -> HotkeyShortcut? { shortcuts[name] }

    func setShortcut(_ shortcut: HotkeyShortcut?, for name: HotkeyName) { shortcuts[name] = shortcut }

    func setHandler(for name: HotkeyName, _ action: @escaping @MainActor () -> Void) { handlers[name] = action }

    func removeHandler(for name: HotkeyName) { handlers[name] = nil }
}

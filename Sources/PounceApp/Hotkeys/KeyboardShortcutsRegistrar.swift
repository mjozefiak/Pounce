import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    init(_ name: HotkeyName) {
        self.init(name.rawValue)
    }
}

extension HotkeyShortcut {
    init(_ shortcut: KeyboardShortcuts.Shortcut) {
        self.init(carbonKeyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers)
    }

    var keyboardShortcut: KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(carbonKeyCode: carbonKeyCode, carbonModifiers: carbonModifiers)
    }
}

/// Global shortcuts through KeyboardShortcuts: stored in `UserDefaults.standard` under
/// `KeyboardShortcuts_<name>` and registered with Carbon while a handler listens.
final class KeyboardShortcutsRegistrar: HotkeyRegistrar {
    private var listeners: [HotkeyName: Task<Void, Never>] = [:]

    func shortcut(for name: HotkeyName) -> HotkeyShortcut? {
        KeyboardShortcuts.getShortcut(for: .init(name)).map(HotkeyShortcut.init)
    }

    func setShortcut(_ shortcut: HotkeyShortcut?, for name: HotkeyName) {
        KeyboardShortcuts.setShortcut(shortcut?.keyboardShortcut, for: .init(name))
    }

    func setHandler(for name: HotkeyName, _ action: @escaping @MainActor () -> Void) {
        listeners[name]?.cancel()
        let events = KeyboardShortcuts.events(.keyDown, for: .init(name))
        listeners[name] = Task { @MainActor in
            for await _ in events {
                action()
            }
        }
    }

    func removeHandler(for name: HotkeyName) {
        // Cancelling ends the event stream, which removes the handler and unregisters the shortcut.
        listeners.removeValue(forKey: name)?.cancel()
    }
}

/// QA mode: shortcuts live in the in-memory registrar, and the recorder views read them from the
/// volatile registration domain, so nothing is persisted or registered with the system.
final class PreviewHotkeyRegistrar: HotkeyRegistrar {
    private let memory = InMemoryHotkeyRegistrar()

    func shortcut(for name: HotkeyName) -> HotkeyShortcut? { memory.shortcut(for: name) }

    func setShortcut(_ shortcut: HotkeyShortcut?, for name: HotkeyName) {
        memory.setShortcut(shortcut, for: name)
        let key = "KeyboardShortcuts_\(name.rawValue)"
        if let shortcut, let data = try? JSONEncoder().encode(shortcut.keyboardShortcut),
            let json = String(data: data, encoding: .utf8)
        {
            UserDefaults.standard.register(defaults: [key: json])
        }
    }

    func setHandler(for name: HotkeyName, _ action: @escaping @MainActor () -> Void) {}

    func removeHandler(for name: HotkeyName) {}
}

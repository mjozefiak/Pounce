import Foundation
import KeyboardShortcuts
import LintelKit

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

    func setKeyEventHandler(for name: HotkeyName, _ handler: @escaping @MainActor (KeyPhase) -> Void) {
        listeners[name]?.cancel()
        // One stream carries both phases, consumed by one loop on the main actor, so their order is the
        // stream's order.
        listeners[name] = Self.forward(KeyboardShortcuts.events(for: .init(name)), to: handler)
    }

    /// Hands each event of the stream to `handler` on the main actor, one at a time, in stream order.
    /// Cancelling the task ends the stream.
    static func forward(
        _ events: AsyncStream<KeyboardShortcuts.EventType>,
        to handler: @escaping @MainActor (KeyPhase) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            for await event in events {
                handler(event == .keyDown ? .down : .up)
            }
        }
    }

    func claimEscape(_ action: @escaping @MainActor () -> Void) -> EscapeKeyClaim {
        CarbonEscapeRegistration.claim(action)
    }

    func removeHandler(for name: HotkeyName) {
        // Cancelling ends the event stream, which removes the handler and unregisters the shortcut.
        listeners.removeValue(forKey: name)?.cancel()
    }
}

#if DEBUG
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

    func setKeyEventHandler(for name: HotkeyName, _ handler: @escaping @MainActor (KeyPhase) -> Void) {}

    /// QA mode never takes the tester's Escape key.
    func claimEscape(_ action: @escaping @MainActor () -> Void) -> EscapeKeyClaim { .inactive }

    func removeHandler(for name: HotkeyName) {}
}
#endif

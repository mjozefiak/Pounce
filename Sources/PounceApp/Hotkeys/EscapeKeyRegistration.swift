import Carbon.HIToolbox
import Foundation
import PounceKit

/// A global Escape shortcut without modifiers (a Carbon hot key), held only while a plugin has claimed
/// the key. KeyboardShortcuts cannot report a failed registration, and this one has to: another app
/// holding Escape makes `isActive` false.
final class CarbonEscapeRegistration {
    private nonisolated final class Box: @unchecked Sendable {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    }

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var box: Unmanaged<Box>?

    /// Registers Escape and returns the claim; an inactive one when the system refuses.
    static func claim(_ action: @escaping @MainActor () -> Void) -> EscapeKeyClaim {
        let registration = CarbonEscapeRegistration()
        guard registration.register(action) else { return .inactive }
        return EscapeKeyClaim(isActive: true) { registration.unregister() }
    }

    private func register(_ action: @escaping @MainActor () -> Void) -> Bool {
        let retained = Unmanaged.passRetained(Box(action))
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), escapeHotKeyHandler, 1, &eventType, retained.toOpaque(), &handlerRef)
        guard installed == noErr else {
            retained.release()
            return false
        }
        var hotKeyRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x504E_4345), id: 1)
        let registered = RegisterEventHotKey(
            UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            RemoveEventHandler(handlerRef)
            retained.release()
            return false
        }
        hotKey = hotKeyRef
        handler = handlerRef
        box = retained
        return true
    }

    /// Idempotent.
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        box?.release()
        hotKey = nil
        handler = nil
        box = nil
    }

    fileprivate nonisolated static func fire(_ userData: UnsafeMutableRawPointer) {
        let box = Unmanaged<Box>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { box.action() }
    }
}

/// The Carbon callback; application events arrive on the main thread.
private nonisolated func escapeHotKeyHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    CarbonEscapeRegistration.fire(userData)
    return noErr
}

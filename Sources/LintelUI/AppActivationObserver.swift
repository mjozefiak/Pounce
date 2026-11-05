import AppKit

/// Calls its handler each time Lintel becomes the active app, for example when the user comes back from System
/// Settings after granting a permission. Plugins re-check what the system may have changed here, so their
/// `settingsStatus` getters can stay read-only (the shell reads them while the view draws). Tests pass their own
/// notification centre and post `NSApplication.didBecomeActiveNotification` to it.
@MainActor public final class AppActivationObserver {
    private let center: NotificationCenter
    private var token: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - center: where the activation is posted; `NotificationCenter.default` in the app.
    ///   - handler: runs on the main queue once per activation, until `stop()`.
    public init(center: NotificationCenter = .default, _ handler: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    /// Stops observing; the handler is not called again.
    public func stop() {
        if let token { center.removeObserver(token) }
        token = nil
    }
}

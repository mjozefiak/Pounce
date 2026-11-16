import Foundation
import LintelKit

/// The one place that decides whether a command may move windows: only while Accessibility is trusted. Without it
/// nothing moves and the HUD says why, with a button that opens the setting.
@MainActor
struct AccessibilityGate {
    let trust: AccessibilityTrust
    let hud: any WindowsHUDPresenting

    /// Reads the permission now. Returns `true` when windows may be moved; otherwise the HUD has been shown.
    func allows(_ purpose: AccessibilityPurpose) -> Bool {
        guard trust.refresh() else {
            hud.show(.accessibilityNeeded(purpose))
            return false
        }
        return true
    }

    /// Runs `body` only when `allows(purpose)`.
    func run(_ purpose: AccessibilityPurpose, _ body: () async -> Void) async {
        guard allows(purpose) else { return }
        await body()
    }
}

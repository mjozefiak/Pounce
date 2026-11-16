import Foundation

/// *Copy diagnostics* (spec: Architecture, "Local diagnostics"): counters only. There is no telemetry, so this
/// is how the owner learns that the watchdog tripped. No window title, no bundle id, no path.
enum WindowsDiagnostics {
    static func report(
        _ diagnostics: EngineDiagnostics, recoveredWindows: Int, parkedWindows: Int, workspaceCount: Int,
        accessibilityTrusted: Bool
    ) -> String {
        [
            "Lintel Window Management diagnostics",
            "Accessibility trusted: \(accessibilityTrusted ? "yes" : "no")",
            "Workspaces: \(workspaceCount)",
            "Windows parked now: \(parkedWindows)",
            "Windows restored by recovery: \(recoveredWindows)",
            "Accessibility timeouts: \(diagnostics.accessibilityTimeouts)",
            "Stubborn windows: \(diagnostics.stubbornWindows)",
            "Echoes dropped: \(diagnostics.echoesDropped)",
            "Watchdog trips: \(diagnostics.watchdogTrips)",
            "Re-hides: \(diagnostics.rehides)",
            "Refused parks: \(diagnostics.refusedParks)",
        ].joined(separator: "\n")
    }
}

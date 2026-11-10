#if DEBUG
import Foundation

/// DEBUG only. The QA bundle (`com.lintelapp.Lintel.QA`, executable `Lintel-QA`, `scripts/make-app.sh`) isolates its
/// data, settings, Keychain and hotkeys only through the `--qa` launch argument: the Keychain services and the
/// Application Support root are not derived from the bundle id, and an app started without `--qa` also runs the
/// one-time legacy defaults migration. Started by a double-click, `open` or a name-matching helper without `--qa`,
/// the QA bundle would share all of it with the owner's real Lintel, so it refuses to start: before any data,
/// Keychain, defaults or window is touched, with a reason on stderr and in the log, and a normal exit (no trap).
enum QAIdentityGuard {
    static let bundleID = "com.lintelapp.Lintel.QA"
    static let executableName = "Lintel-QA"

    enum Decision: Equatable {
        case allow
        case refuse(String)
    }

    static func decision(bundleID current: String?, executableName current2: String?, arguments: [String]) -> Decision {
        let isQABundle = current == bundleID || current2 == executableName
        // The same test `QAOptions.parse` uses to decide that this is a QA run.
        guard isQABundle, !arguments.contains(where: { $0.hasPrefix("--qa") }) else { return .allow }
        return .refuse(
            "The Lintel QA app only starts with --qa (it would share the Keychain, the data folder and the settings "
                + "of the real Lintel otherwise). Start it as: \(executableName) --qa ...; see docs/qa.md.")
    }

    /// The decision for this process.
    static func decisionForThisProcess() -> Decision {
        decision(
            bundleID: Bundle.main.bundleIdentifier,
            executableName: Bundle.main.executableURL?.lastPathComponent,
            arguments: ProcessInfo.processInfo.arguments)
    }
}
#endif

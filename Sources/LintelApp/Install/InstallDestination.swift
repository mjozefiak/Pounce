import Foundation

/// Where the Move flow puts Lintel (spec `2026-11-19-updates-and-open-source-hygiene`, step 4.2).
enum InstallDecision: Equatable {
    /// Copy into this folder (`/Applications`, or `~/Applications` when the user keeps apps there).
    case direct(folder: URL)
    /// `/Applications` (or an existing copy in it) is not writable without an administrator: offer the
    /// `~/Applications` folder instead, creating it when missing.
    case fallbackToUserApplications(folder: URL)
    /// Reserved: an administrator authorization step would go here, in front of the fallback. Never produced:
    /// Lintel does not ask for authorization, because a copy installed as root would make every later update ask
    /// for an administrator password.
    case needsAuthorization(folder: URL)
}

/// The folder choice, modelled on LetsMove: `~/Applications` when it exists and holds at least one `.app`, otherwise
/// `/Applications`; a folder that cannot be written falls back to `~/Applications`.
enum InstallDestination {
    static let systemApplications = URL(filePath: "/Applications", directoryHint: .isDirectory)

    static func userApplications(home: URL) -> URL {
        home.appending(path: "Applications", directoryHint: .isDirectory)
    }

    /// Pure over the file manager port.
    static func decide(home: URL, files: any InstallFileManaging) -> InstallDecision {
        let user = userApplications(home: home)
        let preferred =
            files.directoryExists(at: user) && files.hasApplicationBundle(in: user) ? user : systemApplications
        let existingCopy = preferred.appending(path: ApplicationLocation.bundleName, directoryHint: .isDirectory)
        let writable =
            files.isWritable(at: preferred)
            && (!files.itemExists(at: existingCopy) || files.isWritable(at: existingCopy))
        if writable { return .direct(folder: preferred) }
        // The home folder is already the preferred one and is not writable: nothing better to offer.
        return preferred == user ? .direct(folder: preferred) : .fallbackToUserApplications(folder: user)
    }

    /// The folder as the alert shows it: `~/Applications` for the home one, never the user name.
    static func displayPath(_ folder: URL, home: URL) -> String {
        folder.standardizedFileURL.path == userApplications(home: home).standardizedFileURL.path
            ? "~/Applications" : folder.standardizedFileURL.path
    }
}

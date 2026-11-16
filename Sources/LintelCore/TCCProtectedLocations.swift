import Foundation

/// Places macOS guards with a privacy prompt (TCC) unless Lintel has Full Disk Access.
///
/// Path mode never opens or stats anything inside these places without Full Disk Access, so typing a path
/// can never show a prompt (spec: file path search, A5):
/// - Desktop, Documents, Downloads and iCloud Drive (`protectedFolderPaths`);
/// - other volumes (`/Volumes/<name>`): removable and network volumes ask for access. The boot volume is
///   reached through `/` instead;
/// - other apps' data (`~/Library/Containers`, `~/Library/Group Containers`).
///
/// Places that answer `EPERM` without a prompt (`~/Library/Mail`) are not listed: reading them simply
/// fails, which path mode shows as "no access".
///
/// Paths are compared without regard to case or Unicode normalisation (the boot volume is
/// case-insensitive, so `~/documents` is `~/Documents`), with the `/System/Volumes/Data` firmlink prefix
/// removed. `resolve` also compares each component it reaches by device and inode with the protected
/// folders, which catches any other spelling.
public enum TCCProtectedLocations {
    /// The firmlink prefix under which the data volume (and so the home folder) is also reachable.
    public static let dataVolumePrefix = "/System/Volumes/Data"
    /// Desktop, Documents, Downloads and iCloud Drive under the home folder (FilesPlugin's `ProtectedFolder`
    /// lists the same four; a test keeps them equal).
    public static func protectedFolderPaths(home: String) -> [String] {
        ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { PathText.join(home, $0) }
    }

    /// The protected places below the home folder.
    public static func homeLocations(home: String) -> [String] {
        protectedFolderPaths(home: home) + [
            PathText.join(home, "Library/Containers"),
            PathText.join(home, "Library/Group Containers"),
        ]
    }

    /// Whether `path` (absolute, standardised) is a protected place or inside one.
    public static func requiresFullDiskAccess(_ path: String, home: String) -> Bool {
        let folded = fold(withoutDataPrefix(path))
        if folded.hasPrefix("/volumes/") {
            return true
        }
        return homeLocations(home: home).contains { PathText.contains(fold(withoutDataPrefix($0)), folded) }
    }

    /// Case- and normalisation-insensitive form of a path, for comparisons only.
    public static func fold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The path without a leading `/System/Volumes/Data` (any case).
    public static func withoutDataPrefix(_ path: String) -> String {
        let prefix = dataVolumePrefix.lowercased()
        let lowered = path.lowercased()
        guard lowered == prefix || lowered.hasPrefix(prefix + "/") else { return path }
        let rest = String(path.dropFirst(dataVolumePrefix.count))
        return rest.isEmpty ? "/" : rest
    }
}

import Foundation

/// Finds the provider's binary. No shell, no `PATH` of the app (a GUI app has none worth trusting), no rc files.
public protocol ProviderLocating: Sendable {
    /// The validated, symlink-resolved binary, or nil.
    func locate(_ descriptor: ProviderDescriptor, manualPath: String?) -> URL?
}

/// Looks in a fixed list of directories (or at a path the user chose), resolves symbolic links first and validates the
/// target: a regular executable file owned by the user or root and not writable by group or others. Threat model: a
/// wrong setup, not malware running as the same user.
public struct ProviderLocator: ProviderLocating {
    public let homeDirectory: URL
    public let searchDirectories: [URL]
    /// A resolved target found by the search must live under one of these (the user's home or a package manager's
    /// prefix). A path the user chose by hand is only validated as a file.
    public let allowedRoots: [URL]
    private let userID: uid_t

    public init(
        homeDirectory: URL,
        searchDirectories: [URL]? = nil,
        allowedRoots: [URL]? = nil,
        userID: uid_t = getuid()
    ) {
        self.homeDirectory = homeDirectory
        self.searchDirectories =
            searchDirectories ?? [
                homeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory),
                URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
                URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
            ]
        self.allowedRoots =
            allowedRoots ?? [
                homeDirectory, URL(filePath: "/opt/homebrew", directoryHint: .isDirectory),
                URL(filePath: "/usr/local", directoryHint: .isDirectory),
            ]
        self.userID = userID
    }

    public func locate(_ descriptor: ProviderDescriptor, manualPath: String?) -> URL? {
        if let manualPath, !manualPath.isEmpty {
            return validated(URL(filePath: manualPath), requireAllowedRoot: false)
        }
        for directory in searchDirectories {
            for name in descriptor.binaryNames {
                let candidate = directory.appending(path: name, directoryHint: .notDirectory)
                if let found = validated(candidate, requireAllowedRoot: true) { return found }
            }
        }
        return nil
    }

    func validated(_ candidate: URL, requireAllowedRoot: Bool) -> URL? {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        if requireAllowedRoot {
            let path = resolved.path
            let inside = allowedRoots.contains {
                let root = $0.resolvingSymlinksInPath().standardizedFileURL.path
                return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            guard inside else { return nil }
        }
        var info = stat()
        guard stat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard access(resolved.path, X_OK) == 0 else { return nil }
        guard info.st_uid == userID || info.st_uid == 0 else { return nil }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return nil }
        return resolved
    }
}

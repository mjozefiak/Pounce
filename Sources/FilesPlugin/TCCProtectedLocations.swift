import Darwin
import Foundation

/// Places macOS guards with a privacy prompt (TCC) unless Pounce has Full Disk Access.
///
/// Path mode never opens or stats anything inside these places without Full Disk Access, so typing a path
/// can never show a prompt (spec: file path search, A5):
/// - Desktop, Documents, Downloads and iCloud Drive (`ProtectedFolder`);
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
enum TCCProtectedLocations {
    /// The firmlink prefix under which the data volume (and so the home folder) is also reachable.
    static let dataVolumePrefix = "/System/Volumes/Data"
    /// The protected places below the home folder.
    static func homeLocations(home: String) -> [String] {
        ProtectedFolder.allCases.map { $0.path(home: home) } + [
            PathText.join(home, "Library/Containers"),
            PathText.join(home, "Library/Group Containers"),
        ]
    }

    /// Whether `path` (absolute, standardised) is a protected place or inside one.
    static func requiresFullDiskAccess(_ path: String, home: String) -> Bool {
        let folded = fold(withoutDataPrefix(path))
        if folded.hasPrefix("/volumes/") {
            return true
        }
        return homeLocations(home: home).contains { PathText.contains(fold(withoutDataPrefix($0)), folded) }
    }

    /// Case- and normalisation-insensitive form of a path, for comparisons only.
    static func fold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The path without a leading `/System/Volumes/Data` (any case).
    static func withoutDataPrefix(_ path: String) -> String {
        let prefix = dataVolumePrefix.lowercased()
        let lowered = path.lowercased()
        guard lowered == prefix || lowered.hasPrefix(prefix + "/") else { return path }
        let rest = String(path.dropFirst(dataVolumePrefix.count))
        return rest.isEmpty ? "/" : rest
    }

    /// Device and inode of a file system object.
    struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// The identities of the protected places below the home folder that exist. Statting a protected
    /// folder itself reads only its entry in the home folder, never its contents, so it shows no prompt.
    static func protectedIdentities(home: String) -> Set<Identity> {
        var result = Set<Identity>()
        for path in homeLocations(home: home) {
            var info = stat()
            if lstat(path, &info) == 0 {
                result.insert(Identity(device: info.st_dev, inode: info.st_ino))
            }
        }
        return result
    }

    /// Where a path leads once symbolic links are followed.
    enum Resolution: Hashable, Sendable {
        /// The real path of an existing item.
        case resolved(String)
        /// The path, or a link on the way, leads into a protected place (the first protected path reached).
        case protected(String)
        /// Some component does not exist, or links loop.
        case missing
    }

    /// The most links followed before the path counts as a loop (the system's own limit is 32).
    static let maximumLinks = 32

    /// Follows symbolic links one component at a time and checks every intermediate path **before**
    /// touching it, so a link into `~/Documents` stops at `~/Documents` instead of reading inside it.
    /// - Parameters:
    ///   - path: absolute and standardised.
    ///   - fullDiskAccess: with it, nothing counts as protected.
    static func resolve(_ path: String, home: String, fullDiskAccess: Bool) -> Resolution {
        // Links are followed, so intermediate paths are real paths: compare them with the home folder's
        // real path too (the home folder itself is never protected, so resolving it is safe).
        let homes = Set([home, realPath(home) ?? home])
        func isProtected(_ candidate: String) -> Bool {
            !fullDiskAccess && homes.contains { requiresFullDiskAccess(candidate, home: $0) }
        }
        let identities = fullDiskAccess ? [] : protectedIdentities(home: home)
        var pending = path.split(separator: "/").map(String.init)
        pending.reverse()
        var current = "/"
        var links = 0
        while let component = pending.popLast() {
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                current = PathText.parent(current)
                continue
            }
            let candidate = PathText.join(current, component)
            if isProtected(candidate) {
                return .protected(candidate)
            }
            var info = stat()
            guard lstat(candidate, &info) == 0 else { return .missing }
            // Any other spelling of a protected folder (an odd case or normalisation, a hard-to-guess
            // firmlink) is the same object: stop on it before listing or entering it.
            if identities.contains(Identity(device: info.st_dev, inode: info.st_ino)) {
                return .protected(candidate)
            }
            guard info.st_mode & S_IFMT == S_IFLNK else {
                current = candidate
                continue
            }
            links += 1
            guard links <= maximumLinks, let target = readLink(candidate) else { return .missing }
            // An absolute target starts again from `/`; a relative one continues from the link's folder.
            if target.hasPrefix("/") { current = "/" }
            pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
        }
        return .resolved(current)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

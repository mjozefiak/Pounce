import Darwin
import Foundation
import LintelCore

/// The file-system half of `TCCProtectedLocations`: follows symbolic links without ever reading inside a
/// protected place (spec: file path search, A5). The classification itself is pure and lives in `LintelCore`.
public enum TCCPathResolver {
    /// Device and inode of a file system object.
    public struct Identity: Hashable {
        public let device: dev_t
        public let inode: ino_t
    }

    /// The identities of the protected places below the home folder that exist. Statting a protected
    /// folder itself reads only its entry in the home folder, never its contents, so it shows no prompt.
    public static func protectedIdentities(home: String) -> Set<Identity> {
        var result = Set<Identity>()
        for path in TCCProtectedLocations.homeLocations(home: home) {
            var info = stat()
            if lstat(path, &info) == 0 {
                result.insert(Identity(device: info.st_dev, inode: info.st_ino))
            }
        }
        return result
    }

    /// Where a path leads once symbolic links are followed.
    public enum Resolution: Hashable, Sendable {
        /// The real path of an existing item.
        case resolved(String)
        /// The path, or a link on the way, leads into a protected place (the first protected path reached).
        case protected(String)
        /// Some component does not exist, or links loop.
        case missing
    }

    /// The most links followed before the path counts as a loop (the system's own limit is 32).
    public static let maximumLinks = 32

    /// Follows symbolic links one component at a time and checks every intermediate path **before**
    /// touching it, so a link into `~/Documents` stops at `~/Documents` instead of reading inside it.
    /// - Parameters:
    ///   - path: absolute and standardised.
    ///   - fullDiskAccess: with it, nothing counts as protected.
    public static func resolve(_ path: String, home: String, fullDiskAccess: Bool) -> Resolution {
        // Links are followed, so intermediate paths are real paths: compare them with the home folder's
        // real path too (the home folder itself is never protected, so resolving it is safe).
        let homes = Set([home, realPath(home) ?? home])
        func isProtected(_ candidate: String) -> Bool {
            !fullDiskAccess && homes.contains { TCCProtectedLocations.requiresFullDiskAccess(candidate, home: $0) }
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

    public static func realPath(_ path: String) -> String? {
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

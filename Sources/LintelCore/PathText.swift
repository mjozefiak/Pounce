import Foundation

/// Path string helpers that never touch the file system. `FilesPlugin` adds `expand`, which may (it
/// standardises through `NSString.standardizingPath`, which asks the file system about `/private`).
public enum PathText {
    /// `/a` + `b` = `/a/b`.
    public static func join(_ base: String, _ component: String) -> String {
        base == "/" ? "/" + component : base + "/" + component
    }

    /// The parent folder of a path (`/` for a top-level item).
    public static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// The last component of a path.
    public static func name(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Whether `path` is `ancestor` or lies inside it.
    public static func contains(_ ancestor: String, _ path: String) -> Bool {
        if ancestor == path { return true }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    /// Replaces the home folder with `~`, for display.
    public static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

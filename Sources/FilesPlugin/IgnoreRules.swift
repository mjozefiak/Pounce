import Darwin
import Foundation

/// What the scanner and the watcher leave out of the index (spec step 3.1).
///
/// - Names: default folders that hold generated files (`node_modules`, `.git`, `DerivedData`, caches)
///   plus the user's names and wildcard patterns (`*.tmp`).
/// - Paths: `~/Library` and `~/.Trash` by default, the user's paths, and the protected folders the plan
///   skips without Full Disk Access.
/// - Hidden items (a leading dot or the hidden flag) unless the user turns them on.
///
/// Rules apply to items below a root, never to a root itself.
struct IgnoreRules: Hashable, Sendable {
    /// Folder and file names excluded by default wherever they appear.
    static let defaultNames: Set<String> = [
        "node_modules", ".git", ".hg", ".svn", "DerivedData", ".build", ".cache", "Caches", "__pycache__",
        ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
    ]

    /// Paths below the home folder excluded by default.
    static func defaultPaths(home: String) -> [String] {
        [PathText.join(home, "Library"), PathText.join(home, ".Trash")]
    }

    private(set) var names: Set<String>
    private(set) var patterns: [String]
    private(set) var paths: Set<String>
    let includesHidden: Bool

    init(names: Set<String> = [], patterns: [String] = [], paths: Set<String> = [], includesHidden: Bool = false) {
        self.names = names
        self.patterns = patterns
        self.paths = paths
        self.includesHidden = includesHidden
    }

    /// The defaults plus the user's exclusions. An entry starting with `/` or `~` is a path; an entry with
    /// `*`, `?` or `[` is a name pattern; anything else is an exact name.
    static func make(home: String, userExclusions: [String], includesHidden: Bool) -> IgnoreRules {
        var rules = IgnoreRules(
            names: defaultNames,
            paths: Set(defaultPaths(home: home)),
            includesHidden: includesHidden
        )
        for entry in userExclusions {
            rules.add(entry, home: home)
        }
        return rules
    }

    mutating func add(_ entry: String, home: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            if let path = PathText.expand(trimmed, home: home) {
                paths.insert(path)
            }
        } else if trimmed.contains(where: { "*?[".contains($0) }) {
            if !patterns.contains(trimmed) {
                patterns.append(trimmed)
            }
        } else {
            names.insert(trimmed)
        }
    }

    /// These rules with more excluded paths.
    func excluding(paths more: [String]) -> IgnoreRules {
        var copy = self
        copy.paths.formUnion(more)
        return copy
    }

    /// Whether an item found while scanning is left out.
    /// - Parameters:
    ///   - name: the item's name.
    ///   - path: its absolute path.
    ///   - hiddenFlag: the item carries the `UF_HIDDEN` flag.
    func excludes(name: String, path: String, hiddenFlag: Bool = false) -> Bool {
        if !includesHidden, hiddenFlag || name.hasPrefix(".") {
            return true
        }
        if names.contains(name) || paths.contains(path) {
            return true
        }
        for pattern in patterns where Self.matches(pattern, name) {
            return true
        }
        return false
    }

    /// Whether any component of `path` below `root` is excluded (used for FSEvents paths, whose
    /// ancestors the scanner already filtered).
    func excludesBelow(root: String, path: String) -> Bool {
        guard path != root, PathText.contains(root, path) else { return false }
        var current = root
        let relative = root == "/" ? path.dropFirst() : path.dropFirst(root.count + 1)
        for component in relative.split(separator: "/") {
            current = PathText.join(current, String(component))
            if excludes(name: String(component), path: current) {
                return true
            }
        }
        return false
    }

    /// Shell-style wildcard match on a name (`fnmatch`), case-insensitive.
    static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }

    var fingerprint: String {
        [
            "names=" + names.sorted().joined(separator: "\u{1}"),
            "patterns=" + patterns.joined(separator: "\u{1}"),
            "paths=" + paths.sorted().joined(separator: "\u{1}"),
            "hidden=\(includesHidden)",
        ]
        .joined(separator: "\n")
    }
}

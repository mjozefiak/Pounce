import Foundation
import PounceKit

/// A folder that macOS protects with a privacy prompt (TCC) unless Pounce has Full Disk Access.
///
/// Without Full Disk Access the scan skips these folders, so indexing never shows a series of prompts
/// (spec: Onboarding, Faza 3). The user can add them one at a time and accept the prompt for each.
enum ProtectedFolder: String, CaseIterable, Hashable, Sendable {
    case desktop
    case documents
    case downloads
    /// `~/Library/Mobile Documents`: an exception to the `~/Library` exclusion, indexed as its own root.
    case iCloudDrive = "icloud"

    /// The folder's location under the home folder.
    func path(home: String) -> String {
        switch self {
        case .desktop: PathText.join(home, "Desktop")
        case .documents: PathText.join(home, "Documents")
        case .downloads: PathText.join(home, "Downloads")
        case .iCloudDrive: PathText.join(home, "Library/Mobile Documents")
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .desktop: LocalizedStringResource("Desktop", comment: "Protected folder name")
        case .documents: LocalizedStringResource("Documents", comment: "Protected folder name")
        case .downloads: LocalizedStringResource("Downloads", comment: "Protected folder name")
        case .iCloudDrive: LocalizedStringResource("iCloud Drive", comment: "Protected folder name")
        }
    }
}

/// Which folders the index covers, decided from the settings and the Full Disk Access state.
struct IndexPlan: Hashable, Sendable {
    /// Absolute, standardised root paths; none lies inside another.
    var roots: [String]
    /// Protected folders the scan must skip (inside a root, but not allowed).
    var skippedProtectedPaths: [String]
    /// The protected folders that are indexed.
    var indexedProtected: Set<ProtectedFolder>
    var rules: IgnoreRules

    /// Changes whenever a different plan would index different files; stored in the snapshot, so a
    /// changed plan forces a full scan.
    var fingerprint: String {
        var parts = ["roots=" + roots.joined(separator: "\u{1}")]
        parts.append("skip=" + skippedProtectedPaths.sorted().joined(separator: "\u{1}"))
        parts.append(rules.fingerprint)
        return parts.joined(separator: "\n")
    }
}

/// Decides the index roots (spec step 3.0).
///
/// - Configured roots default to the home folder and `/Applications` (spec Q3). Roots on other volumes
///   (`/Volumes/…`) and firmlink paths (`/System/Volumes/…`) are dropped; a root inside another root is
///   dropped too.
/// - With Full Disk Access, Desktop, Documents and Downloads are indexed with the home folder, and iCloud
///   Drive is its own root unless turned off.
/// - Without it, those folders are skipped unless the user added them one at a time; an added folder
///   that no root contains becomes a root.
enum RootPlanner {
    static func defaultRoots(home: String) -> [String] {
        [home, "/Applications"]
    }

    static func plan(
        configuredRoots: [String]?,
        home: String,
        fullDiskAccess: Bool,
        addedProtected: Set<ProtectedFolder>,
        includesICloudDrive: Bool,
        rules: IgnoreRules
    ) -> IndexPlan {
        let requested = (configuredRoots?.isEmpty ?? true) ? defaultRoots(home: home) : (configuredRoots ?? [])
        var roots = requested.compactMap { PathText.expand($0, home: home) }.filter(isAllowedRoot)

        var skipped: [String] = []
        var indexed = Set<ProtectedFolder>()
        for folder in ProtectedFolder.allCases {
            let path = folder.path(home: home)
            let allowed: Bool =
                if fullDiskAccess {
                    folder != .iCloudDrive || includesICloudDrive
                } else {
                    addedProtected.contains(folder)
                }
            // `~/Library` is excluded by default, so iCloud Drive is only ever indexed as its own root.
            let covered = folder != .iCloudDrive && roots.contains { PathText.contains($0, path) }
            if allowed {
                indexed.insert(folder)
                // iCloud Drive is always its own root; another folder becomes one only when the user added
                // it and no root contains it.
                if !covered, folder == .iCloudDrive || addedProtected.contains(folder) {
                    roots.append(path)
                }
            } else if covered {
                skipped.append(path)
            }
        }
        let effectiveRules = rules.excluding(paths: skipped)
        return IndexPlan(
            roots: removeNested(roots, rules: effectiveRules),
            skippedProtectedPaths: skipped,
            indexedProtected: indexed,
            rules: effectiveRules
        )
    }

    /// Firmlinks (`/System/Volumes/…`) and other volumes (`/Volumes/…`) are never roots.
    static func isAllowedRoot(_ path: String) -> Bool {
        !(path.hasPrefix("/System/Volumes/") || path == "/System/Volumes" || path.hasPrefix("/Volumes/")
            || path == "/Volumes")
    }

    /// Keeps the first occurrence of each root and drops a root that another root's scan already reaches.
    /// A root below an excluded folder (iCloud Drive below `~/Library`) stays, because the outer scan
    /// never gets there.
    static func removeNested(_ roots: [String], rules: IgnoreRules) -> [String] {
        func reaches(_ outer: String, _ inner: String) -> Bool {
            PathText.contains(outer, inner) && !rules.excludesBelow(root: outer, path: inner)
        }
        var result: [String] = []
        for root in roots where !result.contains(root) {
            if result.contains(where: { reaches($0, root) }) {
                continue
            }
            result.removeAll { reaches(root, $0) }
            result.append(root)
        }
        return result
    }
}

/// Path string helpers that never touch the file system.
enum PathText {
    /// `/a` + `b` = `/a/b`.
    static func join(_ base: String, _ component: String) -> String {
        base == "/" ? "/" + component : base + "/" + component
    }

    /// The parent folder of a path (`/` for a top-level item).
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// The last component of a path.
    static func name(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Whether `path` is `ancestor` or lies inside it.
    static func contains(_ ancestor: String, _ path: String) -> Bool {
        if ancestor == path { return true }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    /// Expands `~`, standardises the path and drops a trailing slash. Returns `nil` for a relative path.
    static func expand(_ text: String, home: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute: String
        if trimmed == "~" {
            absolute = home
        } else if trimmed.hasPrefix("~/") {
            absolute = home + trimmed.dropFirst()
        } else if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            return nil
        }
        let standardized = (absolute as NSString).standardizingPath
        return standardized.isEmpty ? nil : standardized
    }

    /// Replaces the home folder with `~`, for display.
    static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

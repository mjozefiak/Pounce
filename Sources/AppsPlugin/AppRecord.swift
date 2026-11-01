import Foundation

/// One installed application as the index knows it. Codable for the `apps.json` cache.
public struct AppRecord: Codable, Hashable, Sendable {
    /// `CFBundleIdentifier`; the item key is `apps:<bundleIdentifier>`.
    public let bundleIdentifier: String
    /// Absolute path of the `.app` bundle.
    public let path: String
    /// The name shown in results: the localised display name.
    public let name: String
    /// Other names the app is found by (`CFBundleName`, `CFBundleDisplayName`, the file name).
    public let aliases: [String]

    public init(bundleIdentifier: String, path: String, name: String, aliases: [String] = []) {
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.name = name
        self.aliases = aliases
    }

    public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

/// Which paths may appear in the app list.
enum AppPathFilter {
    /// Rejects helpers nested in another bundle, hidden or trashed bundles, other volumes, the
    /// read-only system volume mirror and build products. Applies to scanned and Spotlight paths alike.
    static func isEligible(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(".app") else { return false }
        for prefix in ["/Volumes/", "/private/", "/System/Volumes/", "/System/Cryptexes/", "/Library/Developer/"]
        where path.hasPrefix(prefix) {
            return false
        }
        let components = path.split(separator: "/")
        for component in components.dropLast() {
            if component.hasSuffix(".app") || component.hasPrefix(".") || component == "DerivedData" {
                return false
            }
        }
        return !(components.last?.hasPrefix(".") ?? true)
    }
}

/// Merges records from several sources in priority order and keeps one per bundle identifier.
enum AppCatalog {
    /// The first record of each bundle identifier wins, so callers pass the preferred roots first
    /// (`/Applications` before `~/Applications` before the system and Spotlight).
    static func deduplicate(_ records: [AppRecord]) -> [AppRecord] {
        var seen = Set<String>()
        var result: [AppRecord] = []
        for record in records where seen.insert(record.bundleIdentifier).inserted {
            result.append(record)
        }
        return result
    }
}

import Foundation

/// Lists `.app` bundles in the index roots, at most two levels deep (`/Applications/X.app` and
/// `/Applications/Utilities/Y.app`), without descending into any bundle. The directory scan is the
/// source of truth; Spotlight only adds what it misses.
struct AppScanner: Sendable {
    static let maximumDepth = 2

    /// The default roots in priority order.
    static func defaultRoots(home: URL) -> [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Library/CoreServices/Applications", directoryHint: .isDirectory),
        ]
    }

    let roots: [URL]
    /// The localised name of a bundle (`FileManager.displayName(atPath:)` in the app).
    let displayName: @Sendable (URL) -> String?

    init(roots: [URL], displayName: @escaping @Sendable (URL) -> String? = AppScanner.systemDisplayName) {
        self.roots = roots
        self.displayName = displayName
    }

    /// Scans every root, in root order. Returns duplicates; `AppCatalog.deduplicate` removes them.
    func scan() throws -> [AppRecord] {
        var records: [AppRecord] = []
        for root in roots {
            try Task.checkCancellation()
            var bundles: [URL] = []
            collect(root, depth: 1, into: &bundles)
            for bundle in bundles.sorted(by: { $0.path < $1.path }) {
                if let record = record(at: bundle) {
                    records.append(record)
                }
            }
        }
        return records
    }

    /// Reads one bundle, or returns `nil` when it is not a launchable app with a bundle identifier.
    func record(at bundle: URL) -> AppRecord? {
        let path = bundle.standardizedFileURL.path
        guard AppPathFilter.isEligible(path) else { return nil }
        guard let info = Self.infoDictionary(of: bundle) else { return nil }
        guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        if (info["LSBackgroundOnly"] as? Bool) == true || (info["LSBackgroundOnly"] as? String) == "1" {
            return nil
        }

        let fileName = bundle.deletingPathExtension().lastPathComponent
        let bundleName = info["CFBundleName"] as? String
        let bundleDisplayName = info["CFBundleDisplayName"] as? String
        let name =
            Self.nonEmpty(displayName(bundle)) ?? Self.nonEmpty(bundleDisplayName)
            ?? Self.nonEmpty(bundleName) ?? fileName

        var aliases: [String] = []
        var seen: Set<String> = [name.lowercased()]
        for alias in [bundleDisplayName, bundleName, fileName].compactMap(Self.nonEmpty)
        where seen.insert(alias.lowercased()).inserted {
            aliases.append(alias)
        }
        return AppRecord(bundleIdentifier: identifier, path: path, name: name, aliases: aliases)
    }

    private func collect(_ directory: URL, depth: Int, into bundles: inout [URL]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else { return }
        for url in contents {
            if url.pathExtension == "app" {
                bundles.append(url)
                continue
            }
            guard depth < Self.maximumDepth else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true {
                collect(url, depth: depth + 1, into: &bundles)
            }
        }
    }

    /// `Contents/Info.plist`, or `WrappedBundle/Info.plist` for iPhone and iPad apps on the Mac.
    static func infoDictionary(of bundle: URL) -> [String: Any]? {
        for relative in ["Contents/Info.plist", "WrappedBundle/Info.plist"] {
            let url = bundle.appending(path: relative)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return plist
            }
        }
        return nil
    }

    /// The Finder name in the user's language (`Kalkulator` for Calculator in Polish), without `.app`.
    static let systemDisplayName: @Sendable (URL) -> String? = { url in
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

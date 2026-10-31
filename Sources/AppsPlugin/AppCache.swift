import Foundation

/// `apps.json` in the plugin's caches directory: the last app list, so results are available before
/// the first scan of a session finishes. Rebuildable at any time; an unreadable file is ignored.
struct AppCache: Sendable {
    static let fileName = "apps.json"
    static let version = 1

    private struct Payload: Codable {
        let version: Int
        let apps: [AppRecord]
    }

    let directory: URL

    var url: URL { directory.appending(path: Self.fileName) }

    func load() -> [AppRecord]? {
        guard let data = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.version == Self.version
        else { return nil }
        return payload.apps
    }

    /// Writes atomically (temporary file, then rename) with mode 0600 in a 0700 directory.
    func save(_ apps: [AppRecord]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(Payload(version: Self.version, apps: apps))
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

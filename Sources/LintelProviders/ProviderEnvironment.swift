import Foundation

/// The environment of a provider child: only the descriptor's allowlist plus a fixed `PATH`. Everything else the app
/// has, including any other `CLAUDE_*` or `ANTHROPIC_*`, stays behind.
enum ProviderEnvironment {
    static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    static func make(from source: [String: String], allowlist: [String]) -> [String: String] {
        var environment: [String: String] = ["PATH": fixedPath]
        for name in allowlist {
            if let value = source[name], !value.isEmpty, !value.contains("\0") { environment[name] = value }
        }
        return environment
    }
}

/// A new, empty working directory (mode 0700) in the plugin's caches directory, so no `.claude/`, `.mcp.json` or
/// `CLAUDE.md` of a project can be found from it.
struct ProviderWorkspace {
    static let prefix = "provider-"
    let url: URL

    static func make(in base: URL) throws -> ProviderWorkspace {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = base.appending(path: prefix + UUID().uuidString, directoryHint: .isDirectory)
            try manager.createDirectory(
                at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return ProviderWorkspace(url: url)
        } catch {
            throw ProviderError.launchFailed
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes directories a crash left behind. Call once at start, before any run.
    static func sweep(in base: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: base.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? manager.removeItem(at: base.appending(path: name))
        }
    }
}

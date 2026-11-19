import Foundation
import Testing

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The old name must not come back. Every line in the repository that says "Pounce" (any case) carries the
/// `LEGACY-POUNCE` marker (the migration code for the old data folder, Keychain services and defaults domain,
/// kept until v0.2.0), unless it is in one of the exclusions below.
@Suite struct RepositoryNamesTests {
    /// Folders that are not the repository's own text: build output, tooling and the vendored submodule.
    private static let skippedFolders: Set<String> = [
        ".git", ".build", ".swiftpm", "dist", ".claude", "Packages/GRDBCipher/upstream",
    ]
    /// Paths (a folder prefix or a file) that keep the old name on purpose, one reason each.
    private static let excludedPaths: [(path: String, reason: String)] = [
        (".ai/specs/", "history: specs and research name the app as it was when they were written"),
        (".ai/runs/", "history: run plans and handoffs"),
        (".ai/prototypes/", "history: accepted design prototypes"),
        (".uxproof/", "generated design contract, stale until it is regenerated"),
        (".ai/scripts/rename-to-lintel.sh", "the rename tool names both the old and the new names"),
        ("docs/index.html", "the old landing page, removed by its own pull request"),
        ("Tests/LintelAppTests/RepositoryNamesTests.swift", "this test"),
    ]
    /// A line that only names the MVP spec's file name, which keeps its historical name.
    private static let allowedSubstrings = ["pounce-launcher-mvp"]

    private func textFiles() -> [(path: String, text: String)] {
        let rootPath = repositoryRoot.path
        guard
            let walker = FileManager.default.enumerator(
                at: repositoryRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return [] }
        var result: [(String, String)] = []
        for case let url as URL in walker {
            let path = String(url.path.dropFirst(rootPath.count + 1))
            if Self.skippedFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 4_000_000 else { continue }
            if Self.excludedPaths.contains(where: {
                path == $0.path || ($0.path.hasSuffix("/") && path.hasPrefix($0.path))
            }) {
                continue
            }
            if let text = try? String(contentsOf: url, encoding: .utf8) { result.append((path, text)) }
        }
        return result
    }

    @Test func everyPounceNameIsMarkedLegacyOrExcluded() {
        let files = textFiles()
        #expect(files.count > 200, "the scan found too few files, the repository root is probably wrong")
        var unmarked: [String] = []
        for (path, text) in files {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: "pounce", options: .caseInsensitive) != nil && !line.contains("LEGACY-POUNCE")
                && !Self.allowedSubstrings.contains(where: { line.contains($0) })
            {
                unmarked.append("\(path):\(index + 1)")
            }
        }
        #expect(unmarked.isEmpty, "unmarked Pounce names: \(unmarked.joined(separator: ", "))")
    }
}

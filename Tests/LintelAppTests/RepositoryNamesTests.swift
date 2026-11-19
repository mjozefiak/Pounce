import Foundation
import Testing

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The old name must not come back. Every line in the repository that says "Pounce" (any case) carries the
/// `LEGACY-POUNCE` marker (the migration code for the old data folder, Keychain services and defaults domain,
/// kept until v0.2.0), unless it is in one of the exclusions below.
@Suite struct RepositoryNamesTests {
    /// Folders skipped when git is not available: build output, tooling and the vendored submodule.
    private static let skippedFolders: Set<String> = [
        ".git", ".build", ".swiftpm", "dist", ".claude", "Packages/GRDBCipher/upstream",
    ]
    /// Paths (a folder prefix or a file) that keep the old name on purpose, one reason each.
    private static let excludedPaths: [(path: String, reason: String)] = [
        (".ai/specs/", "history: specs and research name the app as it was when they were written"),
        (".ai/runs/", "history: run plans and handoffs"),
        (".ai/prototypes/", "history: accepted design prototypes"),
        (".ai/scripts/rename-to-lintel.sh", "the rename tool names both the old and the new names"),
        ("Tests/LintelAppTests/RepositoryNamesTests.swift", "this test"),
    ]
    /// A line that only names the MVP spec's file name, which keeps its historical name.
    private static let allowedSubstrings = ["pounce-launcher-mvp"]

    /// The files git tracks, so untracked and ignored files in a developer checkout never count; `nil` without
    /// git (a source archive), where every file is the repository's own.
    private func trackedPaths() -> [String]? {
        let git = Process()
        git.executableURL = URL(filePath: "/usr/bin/env")
        git.arguments = ["git", "-C", repositoryRoot.path, "ls-files", "-z"]
        let output = Pipe()
        git.standardOutput = output
        git.standardError = FileHandle.nullDevice
        do { try git.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    private func walkedPaths() -> [String] {
        let rootPath = repositoryRoot.path
        guard let walker = FileManager.default.enumerator(at: repositoryRoot, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [String] = []
        for case let url as URL in walker {
            let path = String(url.path.dropFirst(rootPath.count + 1))
            if Self.skippedFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                walker.skipDescendants()
                continue
            }
            result.append(path)
        }
        return result
    }

    /// Regular UTF-8 files under 4 MB outside the exclusions; binary files fail the UTF-8 read and are skipped.
    private func textFiles() -> [(path: String, text: String)] {
        var result: [(String, String)] = []
        for path in trackedPaths() ?? walkedPaths() {
            if Self.excludedPaths.contains(where: {
                path == $0.path || ($0.path.hasSuffix("/") && path.hasPrefix($0.path))
            }) {
                continue
            }
            let url = repositoryRoot.appending(path: path, directoryHint: .notDirectory)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 4_000_000 else { continue }
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

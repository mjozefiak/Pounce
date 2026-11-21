import Foundation
import Testing

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The repository is public and its history is permanent, so no tracked text file may carry a path from
/// someone's home folder (`/Users/<name>/...`). Write `<repo>/...` or `~/...` instead. A name that is a
/// deliberate fictional example is listed in `allowedNames`, one reason each. The match needs no trailing
/// slash and ignores case (the Mac file system does). Known limits: a name with a space, `~name`,
/// percent-encoded or JSON-escaped (`\/`) forms and other systems' paths are not recognised.
@Suite struct NoHomePathsInRepositoryTests {
    /// Folders skipped when git is not available: build output, tooling and the vendored submodule.
    private static let skippedFolders: Set<String> = [
        ".git", ".build", ".swiftpm", "dist", ".claude", "Packages/GRDBCipher/upstream",
    ]
    /// Names after `/Users/` that are not a real account.
    private static let allowedNames: [(name: String, reason: String)] = [
        ("runner", "the GitHub Actions macOS runner account"),
        ("Shared", "the system's shared folder"),
        ("example", "documentation example"),
        ("<name>", "literal placeholder"),
        ("demo", "fictional home folder in test fixtures"),
        ("tester", "fictional home folder in test fixtures"),
        ("me", "fictional home folder in test fixtures"),
        ("other", "fictional second user in test fixtures"),
        ("someone", "fictional second user in test fixtures"),
        ("…", "elided path in a test of path shortening"),
        ("zo\\u{0301}sia", "escaped, fictional non-ASCII folder name in a Unicode test"),
        ("z\\u{00F3}sia", "escaped, fictional non-ASCII folder name in a Unicode test"),
        ("qa", "fictional home folder of the QA update checker"),
        ("demox", "fictional name that only shares a prefix with `demo`, in a prefix test"),
    ]
    /// Files that must name the pattern itself.
    private static let excludedPaths = ["Tests/LintelAppTests/NoHomePathsInRepositoryTests.swift"]

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

    private func textFiles() -> [(path: String, text: String)] {
        var result: [(String, String)] = []
        for path in trackedPaths() ?? walkedPaths() {
            if Self.excludedPaths.contains(path) || path.hasPrefix("Packages/GRDBCipher/") { continue }
            let url = repositoryRoot.appending(path: path, directoryHint: .notDirectory)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 4_000_000 else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8) { result.append((path, text)) }
        }
        return result
    }

    /// `file:line` of every home path whose name is not allowed; the name itself is never printed.
    private func offenders() throws -> (scanned: Int, hits: [String]) {
        let pattern = try NSRegularExpression(
            pattern: "/Users/([^/\\s\"'`]+)", options: [.caseInsensitive])
        let allowed = Set(Self.allowedNames.map { $0.name.lowercased() })
        let files = textFiles()
        var hits: [String] = []
        for (path, text) in files {
            guard text.range(of: "/Users/", options: .caseInsensitive) != nil else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let string = String(line)
                let range = NSRange(string.startIndex..., in: string)
                for match in pattern.matches(in: string, range: range) {
                    guard let nameRange = Range(match.range(at: 1), in: string) else { continue }
                    if !allowed.contains(string[nameRange].lowercased()) {
                        hits.append("\(path):\(index + 1)")
                        break
                    }
                }
            }
        }
        return (files.count, hits)
    }

    @Test func noTrackedFileNamesAHomeFolder() throws {
        let result = try offenders()
        #expect(result.scanned > 200, "the scan found too few files, the repository root is probably wrong")
        #expect(
            result.hits.isEmpty,
            "home-folder paths (use <repo>/... or ~/...): \(result.hits.joined(separator: ", "))")
    }
}

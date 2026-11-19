import Foundation
import Testing

/// Keeps two repository promises in step with the code: every dependency in the manifest has a third-party notice,
/// and every GitHub Actions `uses:` is pinned to a full commit (spec 2026-11-19-updates-and-open-source-hygiene).
@Suite struct RepositoryHygieneTests {
    /// Dependency identity in a manifest (lowercased package name or binary target name) to the text that must
    /// appear in `THIRD_PARTY_NOTICES.txt`. A new dependency has no entry, so the test fails until it gets one.
    static let noticeMap: [String: [String]] = [
        "grdbcipher": ["GRDB.swift", "SQLCipher"],
        "sqlcipher.swift": ["SQLCipher"],
        "keyboardshortcuts": ["KeyboardShortcuts"],
        "fluidaudio": ["FluidAudio"],
        "argmax-oss-swift": ["WhisperKit"],
        "llama": ["llama.cpp"],
    ]

    private static var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// Identities of the packages (URL last component without `.git`, or the last path component) and binary targets.
    static func dependencies(inManifest manifest: String) -> Set<String> {
        var names = Set<String>()
        let patterns = [
            #"\.package\(\s*url:\s*"[^"]*/([^/"]+?)(?:\.git)?""#,
            #"\.package\(\s*path:\s*"(?:[^"]*/)?([^/"]+)""#,
            #"\.binaryTarget\(\s*name:\s*"([^"]+)""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(manifest.startIndex..., in: manifest)
            for match in regex.matches(in: manifest, range: range) {
                if let r = Range(match.range(at: 1), in: manifest) { names.insert(manifest[r].lowercased()) }
            }
        }
        return names
    }

    /// Problems found: a dependency without a mapping, or whose notice text is missing.
    static func noticeProblems(manifests: [String], notices: String) -> [String] {
        var problems: [String] = []
        for dependency in manifests.reduce(into: Set<String>(), { $0.formUnion(dependencies(inManifest: $1)) }).sorted()
        {
            guard let required = noticeMap[dependency] else {
                problems.append("\(dependency): unknown dependency, add a notice and an entry to noticeMap")
                continue
            }
            for text in required where !notices.contains(text) {
                problems.append("\(dependency): THIRD_PARTY_NOTICES.txt has no notice mentioning \(text)")
            }
        }
        return problems
    }

    /// Every `uses:` value that is neither a local action (`./...`) nor `owner/name@<40 hex>`.
    static func unpinnedActions(inWorkflow text: String) -> [String] {
        var bad: [String] = []
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: #"^\s*(?:-\s+)?uses:\s*(\S+)"#, options: .regularExpression) else {
                continue
            }
            let value = line[range].split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("./") { continue }
            let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
            let sha = parts.count == 2 ? parts[1] : ""
            let isCommit = sha.count == 40 && sha.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            if !isCommit { bad.append(value) }
        }
        return bad
    }

    @Test func everyManifestDependencyHasANotice() throws {
        let manifests = [try Self.read("Package.swift"), try Self.read("Packages/GRDBCipher/Package.swift")]
        let notices = try Self.read("Resources/THIRD_PARTY_NOTICES.txt")
        #expect(Self.noticeProblems(manifests: manifests, notices: notices).isEmpty)
        #expect(
            Self.dependencies(inManifest: manifests[0]).isSuperset(of: ["keyboardshortcuts", "fluidaudio", "llama"]))
    }

    @Test func aRemovedNoticeFails() {
        let manifest = #".package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "1.10.0")"#
        #expect(Self.noticeProblems(manifests: [manifest], notices: "KeyboardShortcuts 1.10.0").isEmpty)
        #expect(!Self.noticeProblems(manifests: [manifest], notices: "FluidAudio 0.18.2").isEmpty)
    }

    @Test func anUnknownDependencyFails() {
        let manifest = #".package(url: "https://github.com/example/NewThing.git", from: "1.0.0")"#
        #expect(!Self.noticeProblems(manifests: [manifest], notices: "NewThing").isEmpty)
        let binary = #".binaryTarget(name: "extra", url: "https://example.com/x.zip", checksum: "00")"#
        #expect(!Self.noticeProblems(manifests: [binary], notices: "extra").isEmpty)
    }

    @Test func workflowActionsArePinnedByCommit() throws {
        let folder = Self.root.appending(path: ".github/workflows", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["yml", "yaml"].contains($0.pathExtension) }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(Self.unpinnedActions(inWorkflow: text).isEmpty, "\(file.lastPathComponent) has a moving action ref")
        }
    }

    @Test func aMovingTagIsDetected() {
        let sha = String(repeating: "a", count: 40)
        let text = """
              - uses: actions/checkout@v7
              - uses: ./.github/actions/local
                uses: owner/name@\(sha) # v1.0.0
              - uses: owner/short@abc123
            """
        #expect(Self.unpinnedActions(inWorkflow: text) == ["actions/checkout@v7", "owner/short@abc123"])
    }
}

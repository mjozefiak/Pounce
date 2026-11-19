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

    /// Identities of the packages (URL last component without `.git`, the last path component, or the registry
    /// identity) and binary targets. The label may follow other arguments, as in `.package(name: "X", path: "...")`.
    static func dependencies(inManifest manifest: String) -> Set<String> {
        var names = Set<String>()
        let patterns = [
            #"\.package\([^)]*?\burl:\s*"[^"]*/([^/"]+?)(?:\.git)?""#,
            #"\.package\([^)]*?\bpath:\s*"(?:[^"]*/)?([^/"]+)""#,
            #"\.package\([^)]*?\bid:\s*"([^"]+)""#,
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

    /// Problems found: a dependency without a mapping, or whose notice is missing. A notice counts only when a line
    /// starts with its text (its title line), so a mention of the name in another notice's prose does not.
    static func noticeProblems(manifests: [String], notices: String) -> [String] {
        let lines = notices.split(whereSeparator: \.isNewline)
        var problems: [String] = []
        for dependency in manifests.reduce(into: Set<String>(), { $0.formUnion(dependencies(inManifest: $1)) }).sorted()
        {
            guard let required = noticeMap[dependency] else {
                problems.append("\(dependency): unknown dependency, add a notice and an entry to noticeMap")
                continue
            }
            for text in required where !lines.contains(where: { $0.hasPrefix(text) }) {
                problems.append("\(dependency): THIRD_PARTY_NOTICES.txt has no notice mentioning \(text)")
            }
        }
        return problems
    }

    /// Every `uses:` value (quotes removed) that is neither a local action (`./...`), `owner/name@<40 hex>`, nor a
    /// Docker image pinned by digest (`docker://image@sha256:<64 hex>`).
    static func unpinnedActions(inWorkflow text: String) -> [String] {
        var bad: [String] = []
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: #"^\s*(?:-\s+)?uses:\s*(\S+)"#, options: .regularExpression) else {
                continue
            }
            let value = line[range].split(separator: ":", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'")))
            if value.hasPrefix("./") { continue }
            let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
            let ref = parts.count == 2 ? parts[1] : ""
            let isPinned =
                value.hasPrefix("docker://")
                ? ref.hasPrefix("sha256:") && isLowercaseHex(ref.dropFirst("sha256:".count), count: 64)
                : isLowercaseHex(Substring(ref), count: 40)
            if !isPinned { bad.append(value) }
        }
        return bad
    }

    private static func isLowercaseHex(_ text: Substring, count: Int) -> Bool {
        text.count == count && text.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
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

    @Test func aNameOnlyMentionedInAnotherNoticeFails() {
        let manifest = #".package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.20.0")"#
        let prose = "SQLite, the database engine inside SQLCipher, is in the public domain.\n"
        #expect(!Self.noticeProblems(manifests: [manifest], notices: prose).isEmpty)
        let notice = prose + "====\nSQLCipher Community Edition 4.20.0\n====\n"
        #expect(Self.noticeProblems(manifests: [manifest], notices: notice).isEmpty)
    }

    @Test func everyPackageFormIsSeen() {
        let manifest = """
            .package(name: "Named", path: "Packages/Named"),
            .package(id: "scope.registered", from: "1.0.0"),
            .package(name: "Old", url: "https://example.com/old-style.git", from: "1.0.0"),
            """
        #expect(Self.dependencies(inManifest: manifest) == ["named", "scope.registered", "old-style"])
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

    @Test func quotesCommentsReusableWorkflowsAndDockerRefs() {
        let sha = String(repeating: "b", count: 40)
        let digest = String(repeating: "c", count: 64)
        let text = """
              - uses: "owner/quoted@\(sha)"
              - uses: 'owner/single@v2'
              # - uses: owner/commented@v1
                uses: owner/repo/.github/workflows/build.yml@main
              - uses: docker://alpine@sha256:\(digest)
              - uses: docker://alpine:3.20
              - uses: owner/upper@\(sha.uppercased())
            """
        #expect(
            Self.unpinnedActions(inWorkflow: text) == [
                "owner/single@v2", "owner/repo/.github/workflows/build.yml@main", "docker://alpine:3.20",
                "owner/upper@\(sha.uppercased())",
            ])
    }
}

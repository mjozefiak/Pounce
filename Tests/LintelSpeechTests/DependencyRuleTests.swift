import Foundation
import Testing

/// ADR 0006: `LintelSpeech` is the shared layer under every plugin, so it depends on nothing from this repository.
/// The SwiftPM graph is the enforcement; this reads `Package.swift` so a dependency added by mistake fails a test.
@Suite struct DependencyRuleTests {
    private static let repositoryTargets = [
        "LintelKit", "LintelCore", "LintelPersistence", "LintelApp", "AppsPlugin", "FilesPlugin", "ClipboardPlugin",
        "DictationPlugin", "MeetingsPlugin",
    ]

    private func manifest() throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
    }

    /// The text of the `.target(name: "LintelSpeech", ...)` declaration.
    private func speechTarget(in manifest: String) throws -> String {
        let start = try #require(manifest.range(of: "name: \"LintelSpeech\""))
        let rest = manifest[start.upperBound...]
        let end = rest.range(of: "\n        ),")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test func theTargetDependsOnNoRepositoryTarget() throws {
        let target = try speechTarget(in: manifest())
        #expect(target.contains("llama"))
        for name in Self.repositoryTargets {
            #expect(!target.contains("\"\(name)\""), "LintelSpeech must not depend on \(name)")
        }
    }

    @Test func noSourceFileImportsARepositoryTarget() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/LintelSpeech", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in Self.repositoryTargets {
                #expect(!text.contains("import \(name)"), "\(file.lastPathComponent) imports \(name)")
            }
        }
    }
}

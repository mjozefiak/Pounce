import Foundation
import Testing

/// DICT-3.0: `TCCProtectedLocations` (`LintelCore`) and `TCCPathResolver` (`LintelPersistence`) sit under the
/// plugins, so the host and any plugin can ask whether a path is TCC-protected without importing `FilesPlugin`.
/// The SwiftPM graph is the enforcement; this reads `Package.swift` and the sources so a dependency added by
/// mistake fails a test.
@Suite struct SharedTCCDependencyTests {
    private static let pluginTargets = [
        "LintelApp", "AppsPlugin", "FilesPlugin", "ClipboardPlugin", "DictationPlugin", "MeetingsPlugin",
        "NotesPlugin", "WindowsPlugin",
    ]

    private var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The text of the target declaration that starts with `name: "<name>",`.
    private func target(_ name: String) throws -> String {
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let start = try #require(manifest.range(of: "name: \"\(name)\","))
        let rest = manifest[start.upperBound...]
        let end = rest.range(of: "\n        ),")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test(arguments: ["LintelCore", "LintelPersistence"])
    func theSharedTargetsDependOnNoPlugin(name: String) throws {
        let declaration = try target(name)
        for plugin in Self.pluginTargets {
            #expect(!declaration.contains("\"\(plugin)\""), "\(name) must not depend on \(plugin)")
        }
    }

    @Test(arguments: ["LintelCore", "LintelPersistence"])
    func theSharedSourcesImportNoPlugin(name: String) throws {
        let folder = root.appending(path: "Sources/\(name)", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for plugin in Self.pluginTargets {
                #expect(!text.contains("import \(plugin)"), "\(file.lastPathComponent) imports \(plugin)")
            }
        }
    }

    @Test func theCheckLivesInTheSharedTargets() throws {
        let core = try String(
            contentsOf: root.appending(path: "Sources/LintelCore/TCCProtectedLocations.swift"), encoding: .utf8)
        let persistence = try String(
            contentsOf: root.appending(path: "Sources/LintelPersistence/TCCPathResolver.swift"), encoding: .utf8)
        #expect(core.contains("public enum TCCProtectedLocations"))
        #expect(persistence.contains("public enum TCCPathResolver"))
    }

    @Test(arguments: ["LintelApp", "MeetingsPlugin"])
    func theHostAndMeetingsReachTheCheckDirectly(name: String) throws {
        let declaration = try target(name)
        #expect(declaration.contains("\"LintelCore\""), "\(name) should depend on LintelCore")
        #expect(declaration.contains("\"LintelPersistence\""), "\(name) should depend on LintelPersistence")
        if name == "MeetingsPlugin" {
            #expect(!declaration.contains("\"FilesPlugin\""), "MeetingsPlugin must not depend on FilesPlugin")
        }
    }
}

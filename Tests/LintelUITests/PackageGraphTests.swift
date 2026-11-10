import Foundation
import Testing

/// ADR 0008, decision 8: `LintelUI` sits under the plugins, so it depends on `LintelKit` and `LintelCore` only and
/// never on a plugin or `LintelApp`. The SwiftPM graph is the enforcement; this reads `Package.swift` and the
/// sources so a dependency added by mistake fails a test.
@Suite struct PackageGraphTests {
    private static let allowedImports: Set<String> = ["LintelKit", "LintelCore", "SwiftUI", "AppKit"]
    private static let forbiddenTargets = [
        "LintelPersistence", "LintelSpeech", "LintelApp", "AppsPlugin", "FilesPlugin", "ClipboardPlugin",
        "DictationPlugin", "MeetingsPlugin", "WindowsPlugin",
    ]

    private var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The text of the `.target(name: "LintelUI", ...)` declaration.
    private func uiTarget() throws -> String {
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let start = try #require(manifest.range(of: ".target(\n            name: \"LintelUI\""))
        let rest = manifest[start.upperBound...]
        let end = rest.range(of: "\n        ),")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test func theTargetDependsOnlyOnTheKitAndTheCore() throws {
        let target = try uiTarget()
        #expect(target.contains("dependencies: [\"LintelKit\", \"LintelCore\"]"))
        for name in Self.forbiddenTargets {
            #expect(!target.contains("\"\(name)\""), "LintelUI must not depend on \(name)")
        }
        #expect(!target.contains(".product("), "LintelUI takes no package dependency")
    }

    @Test func everySourceFileImportsOnlyTheAllowedModules() throws {
        let folder = root.appending(path: "Sources/LintelUI", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ")
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count else { continue }
                // `import` as the first keyword, after attributes such as `@testable` or `public`.
                guard words[..<index].allSatisfy({ $0.hasPrefix("@") || $0 == "public" }) else { continue }
                let module = String(words[index + 1].split(separator: ".").first ?? "")
                #expect(Self.allowedImports.contains(module), "\(file.lastPathComponent) imports \(module)")
            }
        }
    }
}

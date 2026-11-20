import Foundation
import Testing

/// `LintelTestSupport` is test infrastructure: it imports Foundation, Synchronization, Observation and Testing
/// only, depends on no repository target, and no non-test target may depend on it (so `scripts/make-app.sh` never
/// ships it). This reads `Package.swift` and the sources so a mistake fails a test.
@Suite struct PackageGraphTests {
    private static let allowedImports: Set<String> = ["Foundation", "Synchronization", "Observation", "Testing"]

    private var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every top-level target declaration of `Package.swift`: its kind (`target`, `executableTarget`, `testTarget`)
    /// and its text.
    private func declarations() throws -> [(kind: String, text: String)] {
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let lines = manifest.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [(kind: String, text: String)] = []
        var current: (kind: String, lines: [String])?
        for line in lines {
            if let match = line.firstMatch(of: /^        \.(target|executableTarget|testTarget|binaryTarget)\(/) {
                if let current { result.append((current.kind, current.lines.joined(separator: "\n"))) }
                current = (String(match.1), [line])
            } else if line.hasPrefix("    ]") {
                if let current { result.append((current.kind, current.lines.joined(separator: "\n"))) }
                current = nil
            } else if current != nil {
                current?.lines.append(line)
            }
        }
        return result
    }

    @Test func theSupportTargetIsDeclaredOnceAsALibraryNextToItsTests() throws {
        let all = try declarations()
        let support = all.filter { $0.text.contains("name: \"LintelTestSupport\"") }
        #expect(support.count == 1)
        #expect(support.first?.kind == "target")
        #expect(support.first?.text.contains("path: \"Tests/LintelTestSupport\"") == true)
        #expect(all.contains { $0.kind == "testTarget" && $0.text.contains("name: \"LintelTestSupportTests\"") })
    }

    @Test func noNonTestTargetDependsOnTheSupportTarget() throws {
        let nonTest = try declarations().filter {
            $0.kind != "testTarget" && !$0.text.contains("name: \"LintelTestSupport\"")
        }
        #expect(nonTest.count > 5, "the scan found the package's targets")
        for declaration in nonTest {
            #expect(
                !declaration.text.contains("\"LintelTestSupport\""), "a non-test target depends on LintelTestSupport")
        }
    }

    @Test func theSupportTargetDependsOnNoRepositoryTargetAndNoPackage() throws {
        let text = try #require(try declarations().first { $0.text.contains("name: \"LintelTestSupport\"") }).text
        #expect(!text.contains("dependencies:"), "LintelTestSupport takes no dependency")
        #expect(!text.contains(".product("))
    }

    @Test func everySourceFileImportsOnlyTheAllowedModules() throws {
        let folder = root.appending(path: "Tests/LintelTestSupport", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ")
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count else { continue }
                guard words[..<index].allSatisfy({ $0.hasPrefix("@") || $0 == "public" }) else { continue }
                let module = String(words[index + 1].split(separator: ".").first ?? "")
                #expect(Self.allowedImports.contains(module), "\(file.lastPathComponent) imports \(module)")
            }
        }
    }
}

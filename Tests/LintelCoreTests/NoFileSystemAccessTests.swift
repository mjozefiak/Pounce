import Foundation
import Testing

/// `LintelCore` is pure logic without file or network I/O (AGENTS.md; DICT-3.0 criterion 2): the TCC
/// classification works on a path and a home folder passed in. This scans the sources (comments skipped) for
/// calls that reach the file system or the network.
@Suite struct NoFileSystemAccessTests {
    private static let forbidden = [
        "FileManager", "FileHandle", "lstat(", "stat(", "realpath(", "readlink(", "fopen(", "opendir(",
        "standardizingPath", "resolvingSymlinksInPath", "String(contentsOf", "Data(contentsOf", ".write(to:",
        "URLSession", "import Darwin",
    ]

    @Test func noSourceFileReachesTheFileSystem() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/LintelCore", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            for line in code {
                for token in Self.forbidden {
                    #expect(!line.contains(token), "\(file.lastPathComponent) uses \(token)")
                }
            }
        }
    }
}

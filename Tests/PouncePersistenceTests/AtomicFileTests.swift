import Foundation
import PouncePersistence
import Testing

@Suite struct AtomicFileTests {
    @Test func replacesTheFileWithMode0600AndLeavesNoTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "index.snapshot")
        try AtomicFile.write(Data("old".utf8), to: target)
        try AtomicFile.write(Data("new".utf8), to: target)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["index.snapshot"])
    }

    @Test func aFailedWriteKeepsThePreviousFile() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)/x")
        #expect(throws: AtomicFile.WriteError.self) { try AtomicFile.write(Data("x".utf8), to: missing) }
    }
}

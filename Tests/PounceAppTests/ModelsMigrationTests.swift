import Foundation
import PounceKit
import Testing

@testable import PounceApp

@Suite struct ModelsMigrationTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pounce-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(decoding: $0, as: UTF8.self) }
    }

    @Test func movesBothFoldersWithTheirPartialDirectories() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", to: root.appending(path: "Plugins/dictation/Models/parakeet/weights.bin"))
        try write("b", to: root.appending(path: "Plugins/dictation/Models/whisper.partial/chunk"))
        try write("c", to: root.appending(path: "Plugins/dictation/llm/qwen/m.gguf"))

        let outcomes = ModelsMigration(dataRoot: root).run()

        #expect(outcomes == [.moved, .moved])
        #expect(read(root.appending(path: "Models/speech/parakeet/weights.bin")) == "a")
        #expect(read(root.appending(path: "Models/speech/whisper.partial/chunk")) == "b")
        #expect(read(root.appending(path: "Models/llm/qwen/m.gguf")) == "c")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Plugins/dictation/Models").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Plugins/dictation/llm").path))
    }

    @Test func runningAgainChangesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", to: root.appending(path: "Plugins/dictation/Models/p/f"))
        ModelsMigration(dataRoot: root).run()
        let second = ModelsMigration(dataRoot: root).run()
        #expect(second == [.nothingToMove, .nothingToMove])
        #expect(read(root.appending(path: "Models/speech/p/f")) == "a")
    }

    @Test func missingSourceIsNotAnError() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ModelsMigration(dataRoot: root).run() == [.nothingToMove, .nothingToMove])
    }

    @Test func anEmptyTargetFolderCreatedByTheHostIsReplaced() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", to: root.appending(path: "Plugins/dictation/llm/q/m.gguf"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "Models/llm"), withIntermediateDirectories: true)
        #expect(ModelsMigration(dataRoot: root).run().last == .moved)
        #expect(read(root.appending(path: "Models/llm/q/m.gguf")) == "a")
    }

    @Test func whenSourceAndTargetBothHoldFilesNothingIsMergedOrDeleted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("old", to: root.appending(path: "Plugins/dictation/Models/p/f"))
        try write("new", to: root.appending(path: "Models/speech/q/g"))

        let outcomes = ModelsMigration(dataRoot: root).run()

        #expect(outcomes.first == .conflict)
        #expect(read(root.appending(path: "Plugins/dictation/Models/p/f")) == "old")
        #expect(read(root.appending(path: "Models/speech/q/g")) == "new")
        #expect(read(root.appending(path: "Models/speech/p/f")) == nil)
    }

    @Test func aSourceWeCannotMoveFailsWithoutDeletingAnything() throws {
        let root = try makeRoot()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: root.appending(path: "Plugins/dictation").path)
            try? FileManager.default.removeItem(at: root)
        }
        try write("a", to: root.appending(path: "Plugins/dictation/llm/q/m.gguf"))
        // Without write permission on the parent, the rename out of it cannot succeed.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: root.appending(path: "Plugins/dictation").path)

        let outcomes = ModelsMigration(dataRoot: root).run()

        #expect(outcomes.last == .failed)
        #expect(read(root.appending(path: "Plugins/dictation/llm/q/m.gguf")) == "a")
    }

    @Test func prepareCreatesAPrivateModelsFolderInQAMode() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment.qa(QAOptions(dataRoot: root))
        let attributes = try FileManager.default.attributesOfItem(atPath: environment.modelsDirectory.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        #expect(environment.modelsDirectory == root.appending(path: "Models", directoryHint: .isDirectory))
    }
}

extension ModelsMigrationTests {
    @Test func theHostPassesTheSharedModelsFolderToEveryPlugin() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pounce-ctx-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment.qa(QAOptions(dataRoot: root))
        let context = environment.makeContext(
            for: PluginManifest(id: "any", displayName: "Any", symbolName: "circle", order: 1))
        #expect(context.modelsDirectory == root.appending(path: "Models", directoryHint: .isDirectory))
        #expect(!context.modelsDirectory.path.hasPrefix(context.storageDirectory.path))
    }

    @Test func aFileAtTheTargetIsNeverDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pounce-mig-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "Plugins/dictation/llm/q"), withIntermediateDirectories: true)
        try Data("m".utf8).write(to: root.appending(path: "Plugins/dictation/llm/q/m.gguf"))
        try fm.createDirectory(at: root.appending(path: "Models"), withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: root.appending(path: "Models/llm"))

        let outcomes = ModelsMigration(dataRoot: root).run()

        #expect(outcomes.last == .conflict)
        #expect(try Data(contentsOf: root.appending(path: "Models/llm")) == Data("stray".utf8))
        #expect(fm.fileExists(atPath: root.appending(path: "Plugins/dictation/llm/q/m.gguf").path))
    }

    @Test func theMovedFolderIsPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pounce-mig-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appending(path: "Plugins/dictation/Models/p"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "Plugins/dictation/Models/p/f"))
        ModelsMigration(dataRoot: root).run()
        let mode = try fm.attributesOfItem(atPath: root.appending(path: "Models/speech").path)[.posixPermissions]
        #expect((mode as? Int) == 0o700)
    }
}

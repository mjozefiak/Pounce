import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

/// Export All Notes (spec step 4.7): the folder, `manifest.json`, the skipped leftovers and the reconcile first.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesExporterTests {
    @MainActor private struct Rig {
        let harness: NotesHarness
        let store: NotesStore
        let destinationParent: URL

        init() throws {
            harness = try NotesHarness()
            store = try harness.openStore()
            destinationParent = harness.root.appending(path: "out", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        }

        var destination: URL { destinationParent.appending(path: "Lintel Notes", directoryHint: .isDirectory) }

        func manifest(in folder: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: folder.appending(path: "manifest.json"))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func notes(_ manifest: [String: Any]) throws -> [[String: Any]] {
            try #require(manifest["notes"] as? [[String: Any]])
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func exporter(_ rig: Rig) -> NotesExporter {
        var exporter = NotesExporter(store: rig.store)
        exporter.now = { [now] in now }
        return exporter
    }

    @Test func writesOneFilePerHeadAndAManifestWithEveryField() async throws {
        let rig = try Rig()
        defer { withExtendedLifetime(rig) {} }
        let manual = try rig.store.insertDocument(.manual("m", body: "Plan\u{202E}x\n\nSecond", title: "Plan"))
        let overlay = try rig.store.insertDocument(.overlay("m1", body: "Summary\n\nTasks", author: "agent"))
        try rig.store.appendRevision(
            NewNoteRevision(
                docID: overlay.docID, author: "human", state: .applied, body: "Summary\n\nMy tasks", now: now,
                expectedHeadID: overlay.revisionID))
        try rig.store.write { db in
            for (status, quote) in [("open", "Tasks"), ("resolved", "gone")] {
                try db.execute(
                    sql: """
                        INSERT INTO note_comment (doc_id, thread_id, author, created_at, body, anchor_revision_id,
                            anchor_start, anchor_end, anchor_block_hash, anchor_quote, status)
                        VALUES (?, 1, 'human', 5, 'check\u{202E} this', ?, 0, 1, 'h', ?, ?)
                        """, arguments: [overlay.docID, overlay.revisionID, quote, status])
            }
        }
        var exporter = exporter(rig)
        exporter.title = { _ in "Orchard sync" }

        let outcome = try await exporter.export(to: rig.destination)
        #expect(outcome.folder == rig.destination)
        #expect(outcome.noteCount == 2)

        let names = try FileManager.default.contentsOfDirectory(atPath: outcome.folder.path).sorted()
        #expect(names == ["Orchard sync - notes.md", "Plan.md", "manifest.json"])
        // The head, stripped of the bidi override and nothing else.
        let plan = try String(contentsOf: outcome.folder.appending(path: "Plan.md"), encoding: .utf8)
        #expect(plan == "Planx\n\nSecond")
        let mine = try String(contentsOf: outcome.folder.appending(path: "Orchard sync - notes.md"), encoding: .utf8)
        #expect(mine == "Summary\n\nMy tasks")

        let manifest = try rig.manifest(in: outcome.folder)
        #expect(manifest["schema_version"] as? Int == 1)
        #expect(manifest["exported_at"] as? String == "2027-01-15T08:00:00Z")
        let notes = try rig.notes(manifest)
        #expect(notes.count == 2)
        let first = try #require(notes.first { $0["file"] as? String == "Plan.md" })
        #expect(first["doc_id"] as? Int64 == manual.docID)
        #expect(first["key"] as? String == "notes:m")
        #expect(first["kind"] as? String == "manual")
        #expect(first["layer"] as? String == "body")
        #expect(first["title"] as? String == "Plan")
        #expect(first["recording_removed"] as? Bool == false)
        #expect(first["created_at"] as? String == "1970-01-01T00:01:40Z")
        #expect(first["updated_at"] is String)
        #expect(first["authors"] as? [String] == ["human", "human"])
        #expect((first["open_comments"] as? [Any])?.isEmpty == true)

        let second = try #require(notes.first { $0["file"] as? String == "Orchard sync - notes.md" })
        #expect(second["doc_id"] as? Int64 == overlay.docID)
        #expect(second["key"] as? String == "meetings:m1")
        #expect(second["layer"] as? String == "notes")
        // A block of the seed stays the agent's, the edited one is the user's.
        #expect(second["authors"] as? [String] == ["agent", "human"])
        let comments = try #require(second["open_comments"] as? [[String: Any]])
        #expect(comments.count == 1)  // the resolved one is not exported
        #expect(comments.first?["quote"] as? String == "Tasks")
        #expect(comments.first?["body"] as? String == "check this")
        #expect(comments.first?["thread_id"] as? Int == 1)
        #expect(Set(notes.compactMap { $0["doc_id"] as? Int64 }).count == 2)
    }

    @Test func skipsALeftoverDetachedRowAndExportsAKeptOne() async throws {
        let rig = try Rig()
        defer { withExtendedLifetime(rig) {} }
        try rig.store.insertDocument(.overlay("gone", body: "leftover", state: .detached))
        let kept = try rig.store.insertDocument(.overlay("kept", body: "mine", author: "human", state: .detached))
        let outcome = try await exporter(rig).export(to: rig.destination)
        #expect(outcome.noteCount == 1)
        let notes = try rig.notes(try rig.manifest(in: outcome.folder))
        #expect(notes.count == 1)
        #expect(notes[0]["doc_id"] as? Int64 == kept.docID)
        #expect(notes[0]["recording_removed"] as? Bool == true)
    }

    @Test func aRecordedLayerWithoutAnOverlayIsNotExported() async throws {
        let rig = try Rig()
        defer { withExtendedLifetime(rig) {} }
        let outcome = try await exporter(rig).export(to: rig.destination)
        #expect(outcome.noteCount == 0)
        #expect(try rig.notes(try rig.manifest(in: outcome.folder)).isEmpty)
    }

    @Test func everyOverlayIsReconciledBeforeAnythingIsWritten() async throws {
        let rig = try Rig()
        defer { withExtendedLifetime(rig) {} }
        let a = try rig.store.insertDocument(.overlay("a", body: "A"))
        try rig.store.insertDocument(.overlay("a", layer: "transcript", body: "T"))
        try rig.store.insertDocument(.overlay("b", body: "B"))
        let store = rig.store
        var seen: [String] = []
        var exporter = exporter(rig)
        // The reconcile finds that a recording is gone: its unkept overlay goes before the export reads the rows.
        let recorder = KeyRecorder()
        exporter.reconcile = { key in
            recorder.add(key.rawValue)
            if key.id == "b" {
                _ = try? store.detach(key)
                _ = try? store.deleteUnkeptDetached()
            }
        }
        let outcome = try await exporter.export(to: rig.destination)
        seen = recorder.keys
        #expect(seen == ["meetings:a", "meetings:b"])
        let docs = try rig.notes(try rig.manifest(in: outcome.folder)).compactMap { $0["key"] as? String }
        #expect(docs.sorted() == ["meetings:a", "meetings:a"])
        _ = a
    }

    @Test func sameTitlesGetNumberedFileNames() async throws {
        let rig = try Rig()
        defer { withExtendedLifetime(rig) {} }
        try rig.store.insertDocument(.manual("1", body: "one", title: "Plan"))
        try rig.store.insertDocument(.manual("2", body: "two", title: "plan"))
        let outcome = try await exporter(rig).export(to: rig.destination)
        let names = try FileManager.default.contentsOfDirectory(atPath: outcome.folder.path).sorted()
        #expect(
            names == ["Plan (2).md", "Plan.md", "manifest.json"]
                || names == ["Plan.md", "manifest.json", "plan (2).md"])
        #expect(Set(names.map { $0.lowercased() }).count == 3)
    }

    @Test func anExistingFolderIsNeverReplacedAndNoTemporaryFolderStays() async throws {
        let rig = try Rig()
        defer { withExtendedLifetime(rig) {} }
        try FileManager.default.createDirectory(at: rig.destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: rig.destination.appending(path: "mine.txt"))
        try rig.store.insertDocument(.manual("1", body: "one", title: "Plan"))
        let outcome = try await exporter(rig).export(to: rig.destination)
        #expect(outcome.folder.lastPathComponent == "Lintel Notes 2")
        #expect(try String(contentsOf: rig.destination.appending(path: "mine.txt"), encoding: .utf8) == "keep")
        let entries = try FileManager.default.contentsOfDirectory(atPath: rig.destinationParent.path).sorted()
        #expect(entries == ["Lintel Notes", "Lintel Notes 2"])
        // Private data: 0700 folder, 0600 files.
        #expect(try fileMode(outcome.folder) == 0o700)
        #expect(try fileMode(outcome.folder.appending(path: "Plan.md")) == 0o600)
        #expect(try fileMode(outcome.folder.appending(path: "manifest.json")) == 0o600)
    }

    @Test func aFailedWriteThrowsAndLeavesNothingBehind() async throws {
        let rig = try Rig()
        defer { withExtendedLifetime(rig) {} }
        try rig.store.insertDocument(.manual("1", body: "one", title: "Plan"))
        let missing = rig.destinationParent.appending(path: "nope/Lintel Notes", directoryHint: .isDirectory)
        await #expect(throws: NotesExporter.Failure.writeFailed) { try await exporter(rig).export(to: missing) }
        let entries = try FileManager.default.contentsOfDirectory(atPath: rig.destinationParent.path)
        #expect(entries.isEmpty)
    }

    @Test func aClosedStoreThrowsStoreUnavailable() async throws {
        let rig = try Rig()
        defer { withExtendedLifetime(rig) {} }
        try rig.store.close()
        await #expect(throws: NotesExporter.Failure.storeUnavailable) {
            try await exporter(rig).export(to: rig.destination)
        }
    }

    @Test func fileNamesAreSafe() {
        #expect(NotesExporter.stem(title: "a/b:c\\d", layer: nil) == "a b c d")
        #expect(NotesExporter.stem(title: "Sync", layer: "transcript") == "Sync - transcript")
        #expect(NotesExporter.stem(title: String(repeating: "x", count: 200), layer: "notes").count == 60 + 8)
        var names = NotesExporter.FileNames()
        #expect(names.claim(stem: "A") == "A.md")
        #expect(names.claim(stem: "a") == "a (2).md")
        #expect(names.claim(stem: "A") == "A (3).md")
    }
}

/// Collects keys from a `@MainActor` closure.
@MainActor
private final class KeyRecorder {
    private(set) var keys: [String] = []
    func add(_ key: String) { keys.append(key) }
}

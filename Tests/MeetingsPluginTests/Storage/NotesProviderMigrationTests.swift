import Foundation
import GRDB
import LintelPersistence
import Testing

@testable import MeetingsPlugin

/// Migration `v3-notes-provider` (spec `2026-11-10-external-ai-providers`, Data Model): two nullable columns that
/// say which provider and model wrote the notes now in `notes_markdown`. All data is synthetic.
@Suite struct NotesProviderMigrationTests {
    private static let when = Date(timeIntervalSince1970: 1_800_000_000)

    private func openStore() throws -> (MeetingsStore, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        return (try MeetingsStore.open(in: directory.url.appending(path: "meetings"), keys: testKeys()), directory)
    }

    private func readyMeeting(_ store: MeetingsStore, uuid: String = "synthetic-1") throws -> Int64 {
        try store.insertMeeting(uuid: uuid, startedAt: Self.when, speechModelID: "synthetic-model", status: .ready)
    }

    // MARK: Migration

    @Test func aFreshDatabaseHasBothNullableColumnsAndNoMark() throws {
        let queue = try DatabaseQueue()
        try MeetingsStore.migrator.migrate(queue)
        let columns = try queue.read { try Row.fetchAll($0, sql: "PRAGMA table_info(meeting)") }
        for name in ["notes_provider", "notes_provider_model"] {
            let column = try #require(columns.first { ($0["name"] as String) == name })
            #expect((column["type"] as String) == "TEXT")
            #expect((column["notnull"] as Int) == 0)
            #expect((column["dflt_value"] as String?) == nil)
        }
        try queue.write {
            try $0.execute(sql: "INSERT INTO meeting (uuid, started_at, status) VALUES ('n', 1, 'ready')")
        }
        let row = try #require(
            try queue.read {
                try Row.fetchOne($0, sql: "SELECT notes_provider AS p, notes_provider_model AS m FROM meeting")
            })
        #expect((row["p"] as String?) == nil)
        #expect((row["m"] as String?) == nil)
    }

    @Test func aDatabaseFromBeforeTheMigrationKeepsEveryValueAndReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = MeetingsStore.migrator
        try migrator.migrate(queue, upTo: "v2-consent")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (uuid, started_at, title, status, notes_markdown, notes_status,
                        notes_prompt_version, notes_model, notes_dropped_count, consent_text_copied_at)
                    VALUES ('old', 1000, 'Synthetic title', 'ready', '- Synthetic point', 'ok',
                        '5', 'synthetic-catalog-id', 2, 1700000000)
                    """)
        }
        try migrator.migrate(queue)
        #expect(
            try queue.read { try migrator.appliedIdentifiers($0) }
                == ["v1-meetings", "v2-consent", "v3-notes-provider"])
        let row = try #require(
            try queue.read {
                try Row.fetchOne(
                    $0,
                    sql: """
                        SELECT title, notes_markdown, notes_status, notes_prompt_version, notes_model,
                            notes_dropped_count, consent_text_copied_at, notes_provider, notes_provider_model
                        FROM meeting WHERE uuid = 'old'
                        """)
            })
        #expect((row["title"] as String) == "Synthetic title")
        #expect((row["notes_markdown"] as String) == "- Synthetic point")
        #expect((row["notes_status"] as String) == "ok")
        #expect((row["notes_prompt_version"] as String) == "5")
        #expect((row["notes_model"] as String) == "synthetic-catalog-id")
        #expect((row["notes_dropped_count"] as Int) == 2)
        #expect((row["consent_text_copied_at"] as Int64) == 1_700_000_000)
        #expect((row["notes_provider"] as String?) == nil)
        #expect((row["notes_provider_model"] as String?) == nil)
    }

    @Test func runningTheMigratorAgainChangesNothing() throws {
        let queue = try DatabaseQueue()
        let migrator = MeetingsStore.migrator
        try migrator.migrate(queue)
        try queue.write {
            try $0.execute(
                sql: """
                    INSERT INTO meeting (uuid, started_at, status, notes_provider, notes_provider_model)
                    VALUES ('m', 1, 'ready', 'synthetic-provider', 'synthetic-model')
                    """)
        }
        try migrator.migrate(queue)
        try MeetingsStore.migrator.migrate(queue)
        #expect(
            try queue.read { try migrator.appliedIdentifiers($0) }
                == ["v1-meetings", "v2-consent", "v3-notes-provider"])
        let row = try #require(
            try queue.read {
                try Row.fetchOne($0, sql: "SELECT notes_provider AS p, notes_provider_model AS m FROM meeting")
            })
        #expect((row["p"] as String) == "synthetic-provider")
        #expect((row["m"] as String) == "synthetic-model")
    }

    /// `BACKWARD_COMPATIBILITY.md` section 2: a build from before `v3-notes-provider` opens a database that has it,
    /// migrates nothing and loses nothing (the columns are nullable and that build never names them).
    @Test func anOlderBuildOpensTheNewerDatabaseAndLosesNothing() throws {
        let queue = try DatabaseQueue()
        try MeetingsStore.migrator.migrate(queue)
        try queue.write {
            try $0.execute(
                sql: """
                    INSERT INTO meeting (uuid, started_at, status, notes_provider, notes_provider_model)
                    VALUES ('newer', 1000, 'ready', 'synthetic-provider', 'synthetic-model')
                    """)
        }
        var older = DatabaseMigrator()
        older.registerMigration("v1-meetings") { _ in }
        older.registerMigration("v2-consent") { _ in }
        try older.migrate(queue)
        #expect(try queue.read { try older.hasBeenSuperseded($0) })
        // The older build writes a row and updates the notes columns it knows, never naming the new ones.
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meeting (uuid, started_at, status) VALUES ('older', 2000, 'ready')")
            try db.execute(sql: "UPDATE meeting SET notes_status = 'ok', notes_model = 'x' WHERE uuid = 'newer'")
        }
        let rows = try queue.read {
            try Row.fetchAll(
                $0, sql: "SELECT uuid, notes_provider AS p, notes_provider_model AS m FROM meeting ORDER BY uuid")
        }
        #expect(rows.map { $0["uuid"] as String } == ["newer", "older"])
        #expect(rows.map { $0["p"] as String? } == ["synthetic-provider", nil])
        #expect(rows.map { $0["m"] as String? } == ["synthetic-model", nil])
    }

    // MARK: Reading and writing the mark

    @Test func aNewMeetingAndFreshNotesHaveNoMarkUntilAProviderWritesThem() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let id = try readyMeeting(store)
        let before = try #require(try store.notesRecord(of: id))
        #expect(before.provider == nil)
        #expect(before.providerModel == nil)
        _ = try store.beginNotes(id)
        try store.finishNotes(
            id, markdown: "- local", status: .ok, promptVersion: "5", model: "catalog-id", droppedCount: 0,
            generatedAt: Self.when)
        let local = try #require(try store.notesRecord(of: id))
        #expect(local.model == "catalog-id")
        #expect(local.provider == nil)
        #expect(local.providerModel == nil)
    }

    @Test func aProviderResultStoresTheMarkAndLeavesNotesModelNull() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let id = try readyMeeting(store)
        _ = try store.beginNotes(id)
        let outcome = try store.finishNotes(
            id, markdown: "- by provider", status: .ok, promptVersion: "whole1+cli1", model: nil,
            provider: "synthetic-provider", providerModel: "synthetic-model", droppedCount: 1, generatedAt: Self.when)
        #expect(outcome == .stored)
        let record = try #require(try store.notesRecord(of: id))
        #expect(record.provider == "synthetic-provider")
        #expect(record.providerModel == "synthetic-model")
        #expect(record.model == nil)
        #expect(record.promptVersion == "whole1+cli1")
        #expect(record.hasMarkdown)
    }

    @Test func aFailedOrCancelledRunLeavesTheMarkOfTheTextThatIsStillThere() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let id = try readyMeeting(store)
        _ = try store.beginNotes(id)
        try store.finishNotes(
            id, markdown: "- by provider", status: .ok, promptVersion: "whole1+cli1", model: nil,
            provider: "synthetic-provider", providerModel: "synthetic-model", droppedCount: 0, generatedAt: Self.when)
        for settled in [NotesStatus.failed, .ok] {
            let previous = try #require(try store.beginNotes(id))
            #expect(previous == .ok || previous == .failed)
            #expect(try store.settleNotes(id, status: settled))
            let record = try #require(try store.notesRecord(of: id))
            #expect(record.provider == "synthetic-provider")
            #expect(record.providerModel == "synthetic-model")
        }
        // A late write from a job that no longer owns the notes changes nothing either.
        #expect(
            try store.finishNotes(
                id, markdown: "- late", status: .ok, promptVersion: "5", model: "catalog-id", droppedCount: 0,
                generatedAt: Self.when) == .discarded)
        let record = try #require(try store.notesRecord(of: id))
        #expect(record.provider == "synthetic-provider")
        #expect(record.model == nil)
    }

    @Test func notesWrittenAgainByTheBuiltInModelClearTheMark() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let id = try readyMeeting(store)
        _ = try store.beginNotes(id)
        try store.finishNotes(
            id, markdown: "- by provider", status: .ok, promptVersion: "whole1+cli1", model: nil,
            provider: "synthetic-provider", providerModel: "synthetic-model", droppedCount: 0, generatedAt: Self.when)
        _ = try store.beginNotes(id)
        try store.finishNotes(
            id, markdown: "- local again", status: .ok, promptVersion: "5", model: "catalog-id", droppedCount: 0,
            generatedAt: Self.when)
        let record = try #require(try store.notesRecord(of: id))
        #expect(record.provider == nil)
        #expect(record.providerModel == nil)
        #expect(record.model == "catalog-id")
    }

    @Test func aProviderModelWithoutAProviderIsNeverStored() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let id = try readyMeeting(store)
        _ = try store.beginNotes(id)
        try store.finishNotes(
            id, markdown: "- x", status: .ok, promptVersion: "5", model: "catalog-id", provider: nil,
            providerModel: "orphan", droppedCount: 0, generatedAt: Self.when)
        let record = try #require(try store.notesRecord(of: id))
        #expect(record.providerModel == nil)
    }

    @Test func aCatalogModelIsNeverStoredNextToAProvider() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let id = try readyMeeting(store)
        _ = try store.beginNotes(id)
        try store.finishNotes(
            id, markdown: "- by provider", status: .ok, promptVersion: "whole1+cli1", model: "catalog-id",
            provider: "synthetic-provider", providerModel: "synthetic-model", droppedCount: 0, generatedAt: Self.when)
        let record = try #require(try store.notesRecord(of: id))
        #expect(record.provider == "synthetic-provider")
        #expect(record.providerModel == "synthetic-model")
        #expect(record.model == nil)
    }

    @Test func deletingTheMeetingRemovesTheMarkWithTheRow() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let id = try readyMeeting(store)
        _ = try store.beginNotes(id)
        try store.finishNotes(
            id, markdown: "- by provider", status: .ok, promptVersion: "whole1+cli1", model: nil,
            provider: "synthetic-provider", providerModel: "synthetic-model", droppedCount: 0, generatedAt: Self.when)
        try store.deleteMeetings([id])
        #expect(try store.notesRecord(of: id) == nil)
        let leftover = try store.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting WHERE notes_provider IS NOT NULL")
        }
        #expect(leftover == 0)
    }
}

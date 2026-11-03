import Foundation
import GRDB

extension MeetingsStore {
    /// Deletes every meeting that is not being recorded or processed and returns their `uuid`s (their spool
    /// folders). A running session keeps its row and its audio.
    func deleteFinishedMeetings() throws -> [String] {
        try write { db in
            let uuids = try String.fetchAll(
                db, sql: "SELECT uuid FROM meeting WHERE status NOT IN ('recording', 'processing')")
            try db.execute(sql: "DELETE FROM meeting WHERE status NOT IN ('recording', 'processing')")
            return uuids
        }
    }

    func allMeetingUUIDs() throws -> Set<String> {
        try read { db in Set(try String.fetchAll(db, sql: "SELECT uuid FROM meeting")) }
    }
}

/// What the two destructive privacy actions did.
struct PrivacyReport: Equatable {
    /// Meetings removed from the library ("Clear library") or recordings removed ("Delete temporary recordings").
    var removed: Int
}

/// "Clear library" and "Delete temporary recordings" (spec step 1.9). Both are confirmed by the pane before
/// they run. Deleting a file does not overwrite it: on an SSD or a snapshot a copy can outlive it, which the
/// pane says (the audio was encrypted, and the key goes with "Erase Data").
struct MeetingsPrivacyActions {
    let library: MeetingsLibrary
    let spool: SpoolStorage
    let changed: @Sendable () -> Void

    /// Every meeting except one being recorded or processed goes, with its audio spool; spool folders that
    /// no meeting owns go too. The key and the database stay.
    @MainActor
    func clearLibrary() throws -> PrivacyReport {
        guard let store = library.store else { return PrivacyReport(removed: 0) }
        let deleted = try store.deleteFinishedMeetings()
        spool.removeSpools(forMeetings: deleted)
        removeOrphanSpools(keeping: try store.allMeetingUUIDs())
        try? store.vacuum()
        library.refreshCount()
        changed()
        return PrivacyReport(removed: deleted.count)
    }

    /// The audio of interrupted (`incomplete`) meetings goes and their `audio_state` becomes `deleted`; the
    /// transcript stays. Meetings being recorded or processed are not touched.
    @MainActor
    func deleteTemporaryRecordings() throws -> PrivacyReport {
        guard let store = library.store else { return PrivacyReport(removed: 0) }
        let candidates = try store.incompleteSpoolUUIDs()
        spool.removeSpools(forMeetings: candidates)
        // A row whose folder is already gone has no audio either.
        let gone = candidates.filter { uuid in
            UUID(uuidString: uuid).map { !FileManager.default.fileExists(atPath: spool.directory(for: $0).path) }
                ?? false
        }
        try store.markAudioDeleted(uuids: gone)
        changed()
        return PrivacyReport(removed: gone.count)
    }

    private func removeOrphanSpools(keeping owned: Set<String>) {
        let fileManager = FileManager.default
        let items = (try? fileManager.contentsOfDirectory(at: spool.root, includingPropertiesForKeys: nil)) ?? []
        for item in items where !owned.contains(item.lastPathComponent.lowercased()) {
            try? fileManager.removeItem(at: item)
        }
    }
}

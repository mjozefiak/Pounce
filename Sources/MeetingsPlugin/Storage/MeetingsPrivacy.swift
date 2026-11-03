import Foundation
import GRDB

extension MeetingsStore {
    /// Deletes every meeting that is not being recorded or processed and returns their `uuid`s (their spool
    /// folders). A running session keeps its row and its audio, and so does a meeting in `protected` (being
    /// finished: it is `processing` while its audio is replayed).
    func deleteFinishedMeetings(excluding protected: Set<Int64> = []) throws -> [String] {
        try write { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, uuid FROM meeting WHERE status NOT IN ('recording', 'processing')"
            ).filter { !protected.contains($0["id"] as Int64) }
            for row in rows {
                try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [row["id"] as Int64])
            }
            return rows.map { $0["uuid"] as String }
        }
    }
}

/// What the two destructive privacy actions did.
struct PrivacyReport: Equatable {
    /// Meetings removed from the library ("Clear library") or recordings removed ("Delete temporary recordings").
    var removed: Int
    /// Audio folders that could not be removed (still on the disk); the action did not fully succeed.
    var failed = 0
}

/// "Clear library" and "Delete temporary recordings" (spec step 1.9). Both are confirmed by the pane before
/// they run. Deleting a file does not overwrite it: on an SSD or a snapshot a copy can outlive it, which the
/// pane says (the audio was encrypted, and the key goes with "Erase Data").
///
/// Both run synchronously on the main actor, so no `finish()` can start between reading
/// `library.protectedMeetingIDs` and the deletion. The session owner (step 1.10) must keep `MeetingActivity`
/// begun from before it creates a spool folder until the meeting row has its final status, and across the
/// whole "Dokończ"/finish of a meeting; the orphan sweep below refuses to run while it is active.
struct MeetingsPrivacyActions {
    let library: MeetingsLibrary
    let spool: SpoolStorage
    let activity: MeetingActivity?
    let changed: @Sendable () -> Void

    init(
        library: MeetingsLibrary, spool: SpoolStorage, activity: MeetingActivity? = nil,
        changed: @escaping @Sendable () -> Void
    ) {
        self.library = library
        self.spool = spool
        self.activity = activity
        self.changed = changed
    }

    /// Every meeting except one being recorded, processed or finished goes, with its audio spool; spool folders
    /// that no meeting owns go too, unless a session is starting or running (its folder may exist before its
    /// row). The key and the database stay.
    @MainActor
    func clearLibrary() throws -> PrivacyReport {
        guard let store = library.store else { return PrivacyReport(removed: 0) }
        let deleted = try store.deleteFinishedMeetings(excluding: library.protectedMeetingIDs)
        spool.removeSpools(forMeetings: deleted)
        var failed = deleted.filter { remains(spoolOf: $0) }.count
        if activity?.isActive != true {
            failed += removeOrphanSpools(keeping: try store.allMeetingUUIDs())
        }
        try? store.vacuum()
        library.refreshCount()
        changed()
        return PrivacyReport(removed: deleted.count, failed: failed)
    }

    /// The audio of interrupted (`incomplete`) meetings goes and their `audio_state` becomes `deleted`; the
    /// transcript stays. Meetings being recorded, processed or finished are not touched.
    @MainActor
    func deleteTemporaryRecordings() throws -> PrivacyReport {
        guard let store = library.store else { return PrivacyReport(removed: 0) }
        let candidates = try store.incompleteSpoolUUIDs(excluding: library.protectedMeetingIDs)
        spool.removeSpools(forMeetings: candidates)
        // A row whose folder is already gone has no audio either.
        let gone = candidates.filter { !remains(spoolOf: $0) }
        try store.markAudioDeleted(uuids: gone)
        changed()
        return PrivacyReport(removed: gone.count, failed: candidates.count - gone.count)
    }

    /// Whether the spool folder of `uuid` (any kind of entry, a link included) is still on the disk.
    private func remains(spoolOf uuid: String) -> Bool {
        guard let parsed = UUID(uuidString: uuid) else { return false }
        return (try? FileManager.default.attributesOfItem(atPath: spool.directory(for: parsed).path)) != nil
    }

    /// Removes real directories named like a meeting's lower-case UUID that no meeting row owns. Anything else
    /// in the spool root (a stray file, a link, another name) is left alone. Returns how many could not go.
    private func removeOrphanSpools(keeping owned: Set<String>) -> Int {
        let fileManager = FileManager.default
        let owned = Set(owned.map { $0.lowercased() })
        let items = (try? fileManager.contentsOfDirectory(at: spool.root, includingPropertiesForKeys: nil)) ?? []
        var failed = 0
        for item in items {
            let name = item.lastPathComponent.lowercased()
            guard UUID(uuidString: name) != nil, !owned.contains(name) else { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if (try? fileManager.removeItem(at: item)) == nil { failed += 1 }
        }
        return failed
    }
}

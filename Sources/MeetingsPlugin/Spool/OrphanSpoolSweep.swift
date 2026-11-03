import Foundation
import GRDB

/// Removes spool folders that no meeting row owns (a crash between deleting the row and removing the folder,
/// a failed removal after an earlier version, a database restored from elsewhere). Independent of the
/// recovery job: step 1.10 calls `run` once after the library opened and recovery had its pass.
///
/// A folder is only a candidate when
/// - no meeting row has its uuid, and
/// - no live meeting (`liveMeetingIDs`: recording or finalizing in this process) has it, and
/// - it was last written before `now - grace` (a session creates the folder a moment before its row).
/// Removal goes through `SpoolMaintenance.removeSpools(olderThan:among:)`, which touches nothing but the
/// candidates and refuses symbolic links.
enum OrphanSpoolSweep {
    struct Report: Equatable, Sendable {
        var removed: [String] = []
        /// Candidates still on disk afterwards: folders newer than the grace, or ones that could not be removed.
        var remaining: [String] = []
    }

    static let defaultGrace: TimeInterval = 3600

    @discardableResult
    static func run(
        store: MeetingsStore, spool: any SpoolMaintenance, liveMeetingIDs: Set<Int64> = [], now: Date = Date(),
        grace: TimeInterval = defaultGrace
    ) throws -> Report {
        let known = try store.allMeetingUUIDs()
        let live = try store.uuids(ofMeetings: liveMeetingIDs)
        let candidates = Set(spool.spoolFolderNames().map { $0.lowercased() })
            .subtracting(known.map { $0.lowercased() }).subtracting(live.map { $0.lowercased() })
        guard !candidates.isEmpty else { return Report() }
        let removed = spool.removeSpools(olderThan: now.addingTimeInterval(-grace), among: candidates)
        let removedSet = Set(removed)
        let remaining = candidates.subtracting(removedSet).filter { spool.hasSpool(forMeeting: $0) }.sorted()
        return Report(removed: removed.sorted(), remaining: remaining)
    }
}

extension MeetingsStore {
    func uuids(ofMeetings ids: Set<Int64>) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try read { db in
            let marks = ids.map { _ in "?" }.joined(separator: ",")
            return Set(
                try String.fetchAll(
                    db, sql: "SELECT uuid FROM meeting WHERE id IN (\(marks))",
                    arguments: StatementArguments(Array(ids))))
        }
    }
}

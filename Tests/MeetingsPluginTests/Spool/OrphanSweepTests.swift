import Foundation
import Synchronization
import Testing

@testable import MeetingsPlugin

/// A spool that cannot remove anything: the folders stay on "disk".
final class FailingSpool: SpoolMaintenance {
    let existing: Mutex<Set<String>>
    init(existing: Set<String>) { self.existing = Mutex(existing) }
    func removeSpools(forMeetings uuids: [String]) -> [String] { [] }
    func removeSpools(olderThan cutoff: Date, among candidates: Set<String>) -> [String] { [] }
    func hasSpool(forMeeting uuid: String) -> Bool { existing.withLock { $0.contains(uuid) } }
    func spoolFolderNames() -> [String] { existing.withLock { $0.sorted() } }
}

@Suite struct OrphanSweepTests {
    @Test func aFailedSpoolRemovalKeepsTheMeetingAndTheAudio() throws {
        let rig = try WindowRig(status: .incomplete)
        let spool = FailingSpool(existing: ["meeting-uuid"])
        #expect(throws: MeetingActionError.spoolNotRemoved) { try rig.store.deleteMeeting(rig.meetingID, spool: spool) }
        #expect(try rig.store.loadDocument(id: rig.meetingID) != nil, "rolled back")
        #expect(try rig.store.segmentCount(meetingID: rig.meetingID) == 2)
    }

    @Test func deletingRacesFinishAndTheClaimWins() throws {
        let rig = try WindowRig(status: .incomplete)
        #expect(try rig.store.claimForFinishing(rig.meetingID))
        #expect(throws: MeetingActionError.active) { try rig.store.deleteMeeting(rig.meetingID, spool: rig.spool) }
        #expect(try rig.store.loadDocument(id: rig.meetingID)?.status == .processing)
        #expect(rig.spool.state.withLock { $0.removedForMeetings }.isEmpty, "the audio is untouched")
    }

    @Test func theSweepRemovesOnlyFoldersWithoutARowOrALiveMeeting() throws {
        let rig = try WindowRig()
        let live = try rig.store.insertMeeting(
            uuid: "live-uuid", startedAt: Date(), speechModelID: "m", status: .recording)
        let spool = RecordingSpool(existing: ["meeting-uuid", "live-uuid", "orphan-1", "orphan-2"])
        let report = try OrphanSpoolSweep.run(
            store: rig.store, spool: spool, liveMeetingIDs: [live], now: Date(), grace: 60)
        #expect(report.removed == ["orphan-1", "orphan-2"])
        #expect(report.remaining.isEmpty)
        let sweeps = spool.state.withLock { $0.sweeps }
        #expect(sweeps.count == 1)
        #expect(sweeps[0].candidates == ["orphan-1", "orphan-2"])
    }

    @Test func aFailingSpoolIsReportedAndNothingIsLost() throws {
        let rig = try WindowRig()
        let spool = FailingSpool(existing: ["meeting-uuid", "orphan"])
        let report = try OrphanSpoolSweep.run(store: rig.store, spool: spool)
        #expect(report.removed.isEmpty)
        #expect(report.remaining == ["orphan"])
        #expect(try rig.store.loadDocument(id: rig.meetingID) != nil)
    }

    @Test func aRealSpoolFolderWithoutARowIsRemovedAfterTheGrace() throws {
        let rig = try WindowRig()
        let orphan = UUID()
        let storage = SpoolStorage(pluginDirectory: rig.directory.url)
        let folder = try storage.prepare(meeting: orphan)
        #expect(
            try OrphanSpoolSweep.run(store: rig.store, spool: storage, now: Date(), grace: 3600).removed.isEmpty,
            "just written: inside the grace")
        #expect(FileManager.default.fileExists(atPath: folder.path))
        let report = try OrphanSpoolSweep.run(
            store: rig.store, spool: storage, now: Date().addingTimeInterval(7200), grace: 3600)
        #expect(report.removed == [SpoolStorage.name(of: orphan)])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

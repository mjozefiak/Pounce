import Foundation
import LintelKit
import Testing

@testable import MeetingsPlugin

@MainActor @Suite struct MeetingWindowHardeningTests {
    private func handle(_ outcome: ResumeOutcome, onStart: @escaping @Sendable () -> Void = {}) -> MeetingFinishHandle {
        let (events, continuation) = AsyncStream.makeStream(of: ResumeEvent.self)
        continuation.finish()
        return MeetingFinishHandle(events: events, task: Task { outcome })
    }

    @Test func markingSelfMarksNotesStaleOnlyWhenThereAreNotes() async throws {
        let withNotes = try WindowRig(notes: "notes")
        let harness = WindowHarness(withNotes)
        await harness.model.load()
        await harness.model.markSelf(withNotes.anna)
        #expect(harness.model.document?.notesStatus == .stale)

        let without = try WindowRig()
        let other = WindowHarness(without)
        await other.model.load()
        await other.model.markSelf(without.anna)
        #expect(other.model.document?.notesStatus == NotesStatus.none)
        #expect(other.model.document?.notesMarkdown == nil)
    }

    @Test func twoConcurrentEditsBothLandAndTheScreenShowsBoth() async throws {
        let rig = try WindowRig()
        let harness = WindowHarness(rig)
        await harness.model.load()
        async let first: Void = harness.model.renameSpeaker(rig.me, to: "Ola")
        async let second: Void = harness.model.renameSpeaker(rig.anna, to: "Anna")
        _ = await (first, second)
        #expect(harness.model.document?.speakers.map(\.label) == ["Ola", "Anna"])
        let stored = try rig.store.loadDocument(id: rig.meetingID)
        #expect(stored?.speakers.map(\.label) == ["Ola", "Anna"])
    }

    @Test func overlappingLoadsNeverLetAnOlderSnapshotWin() async throws {
        let rig = try WindowRig()
        let harness = WindowHarness(rig)
        await harness.model.load()
        async let a: Void = harness.model.load()
        async let b: Void = harness.model.load()
        async let c: Void = harness.model.renameTitle("Retro")
        _ = await (a, b, c)
        #expect(harness.model.document?.title == "Retro")
        #expect(harness.model.phase == .loaded)
    }

    @Test func deleteIsDisabledWhileFinishing() async throws {
        let rig = try WindowRig(status: .incomplete)
        let gate = Box<CheckedContinuation<Void, Never>?>(nil)
        let harness = WindowHarness(rig) { id, _ in
            try? rig.store.setStatus(id, status: .ready)
            let (events, continuation) = AsyncStream.makeStream(of: ResumeEvent.self)
            Task {
                await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
                continuation.finish()
            }
            return MeetingFinishHandle(events: events, task: Task { .ready })
        }
        await harness.model.load()
        #expect(harness.model.canDelete)
        let running = Task { await harness.model.finish() }
        while !harness.model.isFinishing { await Task.yield() }
        #expect(!harness.model.canDelete)
        harness.model.requestDelete()
        #expect(!harness.model.isConfirmingDelete)
        await harness.model.confirmDelete()
        #expect(try rig.store.loadDocument(id: rig.meetingID) != nil)
        while gate.withLock({ $0 }) == nil { await Task.yield() }
        gate.withLock { $0 }?.resume()
        await running.value
        #expect(harness.model.canDelete)
    }

    @Test func aMeetingThatBecameActiveBehindTheWindowIsNotDeleted() async throws {
        let rig = try WindowRig(status: .incomplete)
        let harness = WindowHarness(rig)
        await harness.model.load()
        harness.model.requestDelete()
        _ = try rig.store.claimForFinishing(rig.meetingID)  // another path claims it before the confirmation
        await harness.model.confirmDelete()
        #expect(harness.model.feedback == .deleteFailed)
        #expect(!harness.model.isDeleted)
        #expect(harness.deleted.withLock { $0 } == 0)
        #expect(harness.model.document?.status == .processing, "the window shows the real state again")
    }

    @Test func aSpoolThatCannotBeRemovedKeepsTheMeetingAndSaysSo() async throws {
        let rig = try WindowRig(status: .incomplete)
        let failing = FailingSpool(existing: ["meeting-uuid"])
        let pasteboard = RecordingPasteboard()
        let model = MeetingWindowModel(
            meetingID: rig.meetingID, store: rig.store, spool: failing, pasteboard: pasteboard,
            saver: FakeFileSaver(), labels: .english, timeZone: ExportFixtures.utc)
        await model.load()
        await model.confirmDelete()
        #expect(model.feedback == .deleteFailed)
        #expect(model.phase == .loaded)
        #expect(try rig.store.loadDocument(id: rig.meetingID) != nil)
    }

    @Test func anUnreadableSpoolOffersFinishingWithAGapAndAcceptsIt() async throws {
        let rig = try WindowRig(status: .incomplete)
        let asked = Box<[Bool]>([])
        let harness = WindowHarness(rig) { id, acceptGap in
            asked.withLock { $0.append(acceptGap) }
            if acceptGap { try? rig.store.setStatus(id, status: .ready) }
            return self.handle(acceptGap ? .ready : .incomplete(.audioUnreadable))
        }
        await harness.model.load()
        await harness.model.finish()
        #expect(harness.model.gapOffer == .audioUnreadable)
        #expect(harness.model.document?.status == .incomplete)
        #expect(!harness.model.isFinishing)

        await harness.model.finish(acceptGap: true)
        #expect(asked.withLock { $0 } == [false, true])
        #expect(harness.model.gapOffer == nil)
        #expect(harness.model.document?.status == .ready)
    }

    @Test func unfinishedSegmentsOfferAGapAndOtherOutcomesSayItCannotBeFinished() async throws {
        let rig = try WindowRig(status: .incomplete)
        let outcome = Box(ResumeOutcome.incomplete(.unfinished(3)))
        let harness = WindowHarness(rig) { _, _ in self.handle(outcome.withLock { $0 }) }
        await harness.model.load()
        await harness.model.finish()
        #expect(harness.model.gapOffer == .unfinished(3))
        outcome.withLock { $0 = .incomplete(.modelUnavailable(busy: false)) }
        await harness.model.finish()
        #expect(harness.model.gapOffer == nil)
        #expect(harness.model.feedback == .finishUnavailable)
    }

    @Test func aTitleOfInvisibleCharactersClearsTheTitleAndKeepsTheFallback() async throws {
        let rig = try WindowRig()
        let harness = WindowHarness(rig)
        await harness.model.load()
        await harness.model.renameTitle("Retro")
        await harness.model.renameTitle("\u{200B}\u{3164}\u{FEFF}")
        #expect(harness.model.document?.title == nil)
        #expect(harness.model.title.contains("2026") || harness.model.title.hasPrefix("Meeting"))
        await harness.model.renameSpeaker(rig.anna, to: "\u{3164}\u{2800}")
        #expect(harness.model.document?.speakers.last?.label == "Mówca 2", "an invisible name is ignored")
    }

    @Test func aSpeakerLabelOfInvisibleCharactersShowsAsUnknown() async throws {
        let rig = try WindowRig()
        try rig.store.write { db in
            try db.execute(sql: "UPDATE meeting_speaker SET label = ? WHERE id = ?", arguments: ["\u{3164}", rig.anna])
        }
        let harness = WindowHarness(rig)
        await harness.model.load()
        let segment = try #require(harness.model.document?.segments.last)
        #expect(harness.model.speakerName(for: segment) == "Unknown speaker")
    }

    @Test func aHostileTitleBecomesASafeFileName() async throws {
        let rig = try WindowRig()
        let harness = WindowHarness(rig)
        await harness.model.load()
        await harness.model.renameTitle("\u{202E}../../.ssh/id:rsa\u{0}\n*?\"<>|" + String(repeating: "x", count: 300))
        let name = harness.model.suggestedFileName()
        #expect(name.hasSuffix(".md"))
        #expect(!name.hasPrefix("."))
        #expect(name.unicodeScalars.count <= 100 + 3)
        for forbidden in ["/", ":", "\\", "\u{202E}", "\u{0}", "\n", "*", "?", "\"", "<", ">", "|"] {
            #expect(!name.contains(forbidden), "\(forbidden)")
        }
        await harness.model.renameTitle("...hidden.")
        #expect(harness.model.suggestedFileName() == "hidden.md")
    }

    @Test func aTypedButNotSubmittedTitleIsSavedOnClose() async throws {
        let rig = try WindowRig()
        let harness = WindowHarness(rig)
        await harness.model.load()
        harness.model.pendingTitle = "Typed on the way out"
        await harness.model.commitPendingTitle()
        #expect(try rig.store.loadDocument(id: rig.meetingID)?.title == "Typed on the way out")
        #expect(harness.model.pendingTitle == nil)
    }

    @Test func theSavedFileIsReadableByTheUserOnly() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "m.md")
        try SavePanelFileSaver.write("x", to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Overwriting a file that was wider keeps it private too.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try SavePanelFileSaver.write("y", to: url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}

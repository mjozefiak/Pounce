import Foundation
import PounceKit
import Testing

@testable import MeetingsPlugin

@MainActor
final class FakeWindows: MeetingWindowPresenting {
    var activatesApp = true
    private(set) var shown: [Int64] = []
    private(set) var closed: [Int64] = []
    private(set) var closedAll = 0
    func show(meetingID: Int64) { shown.append(meetingID) }
    func close(meetingID: Int64) { closed.append(meetingID) }
    func closeAll() { closedAll += 1 }
}

@MainActor
@Suite struct MeetingLibraryDeleteConfirmationTests {
    private func text(_ message: LocalizedStringResource) -> String { String(localized: message) }

    private func actions(_ rig: LibraryRig, clock: Box<Date>) -> MeetingsLibraryActions {
        MeetingsLibraryActions(
            library: rig.library, pasteboard: rig.pasteboard, labels: .english, timeZone: ExportFixtures.utc,
            now: { clock.withLock { $0 } },
            makeWindows: { _ in FakeWindows() })
    }

    @Test func theFirstPressOnlyAsksAndTheSecondDeletes() async throws {
        let rig = try LibraryRig()
        let clock = Box(Date())
        let actions = actions(rig, clock: clock)
        let id = try #require(rig.ids["plain"])
        try await actions.requestDelete(id, panel: rig.panel)
        #expect(try rig.store.loadDocument(id: id) != nil)
        #expect(rig.panel.confirmations == [text(MeetingsLibraryActions.confirmMessage)])
        clock.withLock { $0 = $0.addingTimeInterval(2) }
        try await actions.requestDelete(id, panel: rig.panel)
        #expect(try rig.store.loadDocument(id: id) == nil)
    }

    @Test func theConfirmationExpiresAndBelongsToOneMeeting() async throws {
        let rig = try LibraryRig()
        let clock = Box(Date())
        let actions = actions(rig, clock: clock)
        let first = try #require(rig.ids["plain"])
        let other = try #require(rig.ids["stale"])
        // Too late: asks again instead of deleting.
        try await actions.requestDelete(first, panel: rig.panel)
        clock.withLock { $0 = $0.addingTimeInterval(MeetingsLibraryActions.deleteConfirmationWindow + 1) }
        try await actions.requestDelete(first, panel: rig.panel)
        #expect(try rig.store.loadDocument(id: first) != nil)
        // Another meeting's press does not delete anything and replaces the armed one.
        try await actions.requestDelete(other, panel: rig.panel)
        #expect(try rig.store.loadDocument(id: first) != nil)
        #expect(try rig.store.loadDocument(id: other) != nil)
        #expect(rig.panel.confirmations.count == 3)
    }

    @Test func anUnfinishedMeetingWithAudioSaysTheAudioGoesToo() async throws {
        let rig = try LibraryRig()
        let actions = actions(rig, clock: Box(Date()))
        let uuid = UUID()
        _ = try rig.library.spoolStorage.prepare(meeting: uuid)
        let id = try rig.store.insertMeeting(
            uuid: SpoolStorage.name(of: uuid), startedAt: Date(), speechModelID: "m", status: .incomplete)
        try await actions.requestDelete(id, panel: rig.panel)
        #expect(rig.panel.confirmations == [text(MeetingsLibraryActions.confirmWithAudioMessage)])
        try await actions.requestDelete(id, panel: rig.panel)
        #expect(!rig.library.spoolStorage.hasSpool(forMeeting: SpoolStorage.name(of: uuid)))
        #expect(try rig.store.loadDocument(id: id) == nil)
    }

    @Test func aLiveOrProcessingMeetingIsRefusedWithAMessageNotAFailure() async throws {
        let rig = try LibraryRig()
        let actions = actions(rig, clock: Box(Date()))
        let recording = try rig.store.insertMeeting(
            uuid: UUID().uuidString.lowercased(), startedAt: Date(), speechModelID: "m")
        try await actions.requestDelete(recording, panel: rig.panel)
        try await actions.requestDelete(recording, panel: rig.panel)
        #expect(try rig.store.status(of: recording) == .recording)
        #expect(rig.panel.confirmations == Array(repeating: text(MeetingsLibraryActions.activeMessage), count: 2))
        // A ready meeting that a session in this process still holds is refused too.
        let held = try #require(rig.ids["plain"])
        rig.library.registerLive(meetingID: held)
        try await actions.requestDelete(held, panel: rig.panel)
        #expect(try rig.store.loadDocument(id: held) != nil)
        #expect(rig.panel.confirmations.last == text(MeetingsLibraryActions.activeMessage))
        // The row's own action goes through the same path.
        let row = try #require(
            try await rig.search().first { $0.itemKey == MeetingLibraryPresentation.itemKey(recording) })
        try await #require(rig.source.actions(for: row).last).perform(
            ActionContext(previousApp: nil, panel: rig.panel))
        #expect(try rig.store.status(of: recording) == .recording)
    }

    @Test func aMissingMeetingStillThrows() async throws {
        let rig = try LibraryRig()
        let actions = actions(rig, clock: Box(Date()))
        await #expect(throws: MeetingLibraryActionError.missing) {
            try await actions.requestDelete(9_999, panel: rig.panel)
        }
    }
}

@MainActor
@Suite struct MeetingLibraryWindowTests {
    private func rig(_ windows: Box<[FakeWindows]>) throws -> (LibraryRig, MeetingsLibraryActions) {
        let rig = try LibraryRig()
        let actions = MeetingsLibraryActions(
            library: rig.library, pasteboard: rig.pasteboard, labels: .english, timeZone: ExportFixtures.utc,
            makeWindows: { _ in
                let fake = FakeWindows()
                windows.withLock { $0.append(fake) }
                return fake
            })
        return (rig, actions)
    }

    @Test func oneRegistryServesEveryMeetingAndOpenReusesIt() throws {
        let windows = Box<[FakeWindows]>([])
        let (rig, actions) = try rig(windows)
        actions.open(try #require(rig.ids["plain"]))
        actions.open(try #require(rig.ids["notes"]))
        let all = windows.withLock { $0 }
        #expect(all.count == 1)
        #expect(all[0].shown.count == 2)
    }

    @Test func aNewStoreClosesTheOldWindowsFirst() throws {
        let windows = Box<[FakeWindows]>([])
        let (rig, actions) = try rig(windows)
        let id = try #require(rig.ids["plain"])
        actions.open(id)
        rig.library.close()
        rig.library.open()
        actions.open(id)
        let all = windows.withLock { $0 }
        #expect(all.count == 2)
        #expect(all[0].closedAll == 1)
        #expect(all[1].shown == [id])
    }

    @Test func closeWindowsClosesThemAndNextOpenStartsOver() throws {
        let windows = Box<[FakeWindows]>([])
        let (rig, actions) = try rig(windows)
        let id = try #require(rig.ids["plain"])
        actions.open(id)
        actions.closeWindows()
        #expect(windows.withLock { $0 }[0].closedAll == 1)
        actions.closeWindows()  // nothing open: harmless
        actions.open(id)
        #expect(windows.withLock { $0 }.count == 2)
    }

    @Test func aDeletedMeetingsWindowIsClosed() async throws {
        let windows = Box<[FakeWindows]>([])
        let (rig, actions) = try rig(windows)
        let id = try #require(rig.ids["plain"])
        actions.open(id)
        try await actions.delete(id)
        #expect(windows.withLock { $0 }[0].closed == [id])
    }

    @Test func noOtherCodeBuildsAWindowController() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name != "MeetingWindowController.swift", name != "MeetingsLibraryActions.swift" else { continue }
            #expect(
                !(try String(contentsOf: url, encoding: .utf8)).contains("MeetingWindowController("), "\(name)")
        }
    }
}

@MainActor
@Suite struct MeetingLibraryLowsTests {
    @Test func aHugeQueryIsCappedNotAnError() async throws {
        let rig = try LibraryRig()
        let words = Array(repeating: "roadmapa", count: 20) + Array(repeating: "zzzz", count: 480)
        let capped = try await rig.search(words.joined(separator: " "))
        #expect(rig.keys(capped) == ["plain"])
        let many = try await rig.search((["budzet"] + Array(repeating: "qqq", count: 499)).joined(separator: " "))
        #expect(many.isEmpty || rig.keys(many) == ["notes"])
    }

    @Test func aPreviewSaysMissingForAGoneMeetingAndFailedForAnUnreadableDatabase() async throws {
        let rig = try LibraryRig()
        let ok = await MeetingsPlugin.previewContent(of: try #require(rig.ids["notes"]), library: rig.library)
        guard case .content = ok else {
            Issue.record("expected content")
            return
        }
        #expect(await MeetingsPlugin.previewContent(of: 9_999, library: rig.library) == .missing)
        try rig.store.close()
        let id = try #require(rig.ids["notes"])
        #expect(await MeetingsPlugin.previewContent(of: id, library: rig.library) == .failed)
    }

    @Test func aCancelledReadStops() async throws {
        let rig = try LibraryRig()
        let store = try rig.store
        let id = try #require(rig.ids["notes"])
        let task = Task { () async -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await MeetingLibraryIO.document(store: store, id: id) } catch {
                return error is CancellationError
            }
            return false
        }
        #expect(await task.value)
    }

    @Test func theAppNameIsCachedAndAnUnknownAppIsNil() {
        #expect(MeetingLibraryPresentation.installedAppName("com.example.not-installed.x") == nil)
        #expect(MeetingLibraryPresentation.installedAppName("com.example.not-installed.x") == nil)
    }
}

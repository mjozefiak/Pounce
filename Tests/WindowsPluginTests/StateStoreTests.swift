import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

@Suite struct StateStoreTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func win(_ number: UInt32, pid: Int32 = 100) -> WindowID { WindowID(pid: pid, number: number) }
    private func entry(_ number: UInt32, pid: Int32 = 100, start: Double = 1_000) -> HiddenEntry {
        HiddenEntry(
            windowID: win(number, pid: pid), processStart: start,
            homeFrame: FrameRecord(x: 10, y: 20, width: 300, height: 400))
    }

    private func store(_ harness: WindowsHarness, saveDelay: Duration = .seconds(3600)) -> StateStore {
        StateStore(directory: harness.directory, saveDelay: saveDelay)
    }

    @Test func aMissingFileStartsEmpty() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        await store.load()
        #expect(await store.state == .empty)
        #expect(await store.canJournal)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func theJournalAndMembershipRoundTrip() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let first = store(harness)
        await first.load()
        await first.setOrder([ws(1): [win(1), win(2)], ws(3): [win(3)]])
        try await first.addHidden([entry(2), entry(3)])
        await first.close()

        let second = store(harness)
        await second.load()
        let state = await second.state
        #expect(state.order == [ws(1): [win(1), win(2)], ws(3): [win(3)]])
        #expect(state.hidden == [entry(2), entry(3)])
    }

    @Test func theJournalIsOnDiskBeforeAddHiddenReturns() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        await store.load()
        try await store.addHidden([entry(7)])
        // A kill right here, before anything is parked: a fresh process sees the entry without any flush.
        let after = self.store(harness)
        await after.load()
        #expect(await after.hidden == [entry(7)])
    }

    @Test func deferredMembershipIsNotWrittenUntilFlushed() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        await store.load()
        await store.setOrder([ws(1): [win(1)]])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func aDeferredSaveFiresAfterTheDelay() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let clock = VirtualClock(autoAdvance: false)
        let store = StateStore(directory: harness.directory, clock: clock, saveDelay: .seconds(5))
        await store.load()
        await store.setOrder([ws(2): [win(5)]])
        await clock.waitForSleepers(1)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        clock.advance(5)
        await store.waitForPendingSave()
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        await store.close()
    }

    @Test func aReparkedWindowKeepsItsFirstHomeFrame() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        await store.load()
        try await store.addHidden([entry(1)])
        var parked = entry(1)
        parked.homeFrame = FrameRecord(x: 9_999, y: 9_999, width: 1, height: 1)
        try await store.addHidden([parked])
        #expect(await store.hidden == [entry(1)])
    }

    @Test func removingFromTheJournalIsWrittenThrough() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        await store.load()
        try await store.addHidden([entry(1), entry(2)])
        try await store.removeHidden([win(1)])
        let after = self.store(harness)
        await after.load()
        #expect(await after.hidden == [entry(2)])
    }

    @Test func aStaleProcessStartIsDroppedAndNeverReturned() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        await store.load()
        try await store.addHidden([
            entry(1, pid: 10, start: 1_000),  // same process
            entry(2, pid: 20, start: 1_000),  // pid reused after a reboot: another start time
            entry(3, pid: 30, start: 1_000),  // process gone
        ])
        let valid = try await store.validated { pid in
            switch pid {
            case 10: 1_000.4
            case 20: 5_000
            default: nil
            }
        }
        #expect(valid.map(\.windowID) == [win(1, pid: 10)])
        #expect(await store.hidden.map(\.windowID) == [win(1, pid: 10)])
        // The drop is on disk too.
        let after = self.store(harness)
        await after.load()
        #expect(await after.hidden.map(\.windowID) == [win(1, pid: 10)])
    }

    @Test func aCorruptFileIsSetAsideOnceAndTheStoreStartsEmpty() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        try Data("not json".utf8).write(to: store.fileURL)
        await store.load()
        #expect(await store.state == .empty)
        #expect(await store.canJournal)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(try Data(contentsOf: store.corruptURL) == Data("not json".utf8))

        // A second corrupt file replaces the single copy.
        try Data("{\"version\":1}".utf8).write(to: store.fileURL)
        await store.load()
        #expect(try Data(contentsOf: store.corruptURL) == Data("{\"version\":1}".utf8))
    }

    @Test func aFileWithoutAVersionIsCorrupt() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        try Data("{\"workspaces\":{},\"hidden\":[]}".utf8).write(to: store.fileURL)
        await store.load()
        #expect(FileManager.default.fileExists(atPath: store.corruptURL.path))
    }

    @Test func aNewerFileIsReadOnlyAndIsNeverTouched() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        let text = """
            {"version":2,"workspaces":{"1":{"order":[],"future":true}},"hidden":[{"windowID":{"pid":1,"number":2},"processStart":5,"homeFrame":{"x":1,"y":2,"width":3,"height":4}}],"extra":1}
            """
        try Data(text.utf8).write(to: store.fileURL)
        await store.load()
        #expect(!(await store.canJournal))
        // The journal of a newer file can still be read, so its parked windows can be restored.
        #expect(await store.hidden.map(\.windowID) == [win(2, pid: 1)])
        await #expect(throws: StateStore.StoreError.readOnly) { try await store.addHidden([entry(9)]) }
        await #expect(throws: StateStore.StoreError.readOnly) { try await store.removeHidden([win(2, pid: 1)]) }
        await store.setOrder([ws(1): [win(1)]])
        await store.close()
        #expect(try Data(contentsOf: store.fileURL) == Data(text.utf8))
        #expect(!FileManager.default.fileExists(atPath: store.corruptURL.path))
    }

    @Test func aFailedJournalWriteThrowsAndLeavesTheJournalUnchanged() async throws {
        let harness = try WindowsHarness()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.directory.path)
            harness.tearDown()
        }
        let store = store(harness)
        await store.load()
        try await store.addHidden([entry(1)])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: harness.directory.path)
        await #expect(throws: StateStore.StoreError.write) { try await store.addHidden([entry(2)]) }
        #expect(await store.hidden == [entry(1)])
    }

    @Test func theFileIsPrivateAndHasNoTitlesOrBundleIDs() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = store(harness)
        await store.load()
        try await store.addHidden([entry(1)])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("title"))
        #expect(!text.contains("bundle"))
        #expect(text.contains("\"version\":1"))
    }

    @Test func workspacesOutsideOneThroughNineAreDropped() throws {
        let data = Data(
            """
            {"version":1,"workspaces":{"0":{"order":[]},"4":{"order":[{"pid":1,"number":1}]},"12":{"order":[]},"x":{"order":[]}},"hidden":[]}
            """.utf8)
        guard case .current(let file) = StateStore.decode(data) else {
            Issue.record("expected a current file")
            return
        }
        #expect(file.state.order == [ws(4): [win(1, pid: 1)]])
    }

    @Test func duplicateJournalEntriesAreCollapsedOnRead() throws {
        let record = """
            {"windowID":{"pid":1,"number":2},"processStart":5,"homeFrame":{"x":1,"y":2,"width":3,"height":4}}
            """
        let data = Data("{\"version\":1,\"workspaces\":{},\"hidden\":[\(record),\(record)]}".utf8)
        guard case .current(let file) = StateStore.decode(data) else {
            Issue.record("expected a current file")
            return
        }
        #expect(file.state.hidden.count == 1)
    }
}

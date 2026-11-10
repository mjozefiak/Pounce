import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The echo window per in-flight frame, and the journal operations of one batch.
@Suite(.timeLimit(.minutes(1))) struct EchoAndJournalOrderTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }
    private func entry(_ number: UInt32) -> HiddenEntry {
        HiddenEntry(
            windowID: id(number), processStart: 1_100, homeFrame: FrameRecord(CGRect(x: 1, y: 1, width: 2, height: 2)))
    }

    // MARK: Expected frames

    @Test func everyFrameInFlightIsExpectedAndAnExpiredOrForgottenOneIsNot() {
        var expected = ExpectedFrames()
        let first = CGRect(x: 0, y: 0, width: 10, height: 10)
        let second = CGRect(x: 50, y: 0, width: 10, height: 10)
        expected.expect(generation: 1, frame: first, expires: 10)
        expected.expect(generation: 2, frame: second, expires: 10)
        #expect(expected.matches(first, now: 5, tolerance: 2))
        #expect(expected.matches(second, now: 5, tolerance: 2))
        #expect(!expected.matches(first, now: 11, tolerance: 2))
        expected.restamp(generation: 1, expires: 20)
        #expect(expected.matches(first, now: 15, tolerance: 2))
        #expect(!expected.matches(second, now: 15, tolerance: 2))
        expected.forget(generation: 1)
        #expect(!expected.matches(first, now: 5, tolerance: 2))
    }

    @Test func aFightKeepsOnlyTheNewestFramesInFlight() {
        var expected = ExpectedFrames()
        for generation in 1...(ExpectedFrames.capacity + 3) {
            expected.expect(
                generation: generation, frame: CGRect(x: Double(generation) * 100, y: 0, width: 5, height: 5),
                expires: 10)
        }
        #expect(expected.entries.count == ExpectedFrames.capacity)
        #expect(expected.entries.first?.generation == 4)
    }

    @Test func theEchoOfAnOlderFrameStillInFlightIsNotAUserMove() {
        var state = EngineState(workspaceCount: 2, displays: [FakeWindowClient.mainDisplay])
        state.config.layout = LayoutConfig(defaultKind: .free)
        (state, _) = EngineReducer.reduce(
            state,
            .snapshot(
                windows: [makeWindow(1)], displays: [FakeWindowClient.mainDisplay], focused: nil,
                processStarts: [100: 1_100], now: 1))
        let older = CGRect(x: 300, y: 300, width: 400, height: 300)
        let newer = CGRect(x: 600, y: 100, width: 400, height: 300)
        (state, _) = EngineReducer.reduce(state, .place(id(1), older, now: 2))
        (state, _) = EngineReducer.reduce(state, .place(id(1), newer, now: 2.1))
        // The app reports the older frame, which is still travelling: ours, not the user's.
        (state, _) = EngineReducer.reduce(state, .windowMoved(id(1), frame: older, now: 2.2))
        #expect(state.diagnostics.echoesDropped == 1)
        #expect(state.windows[id(1)]?.frame != older)
    }

    // MARK: Journal order

    @Test func aWindowRestoredAndParkedAgainInOneBatchKeepsItsJournalEntry() {
        let a = id(1)
        let effects: [EngineEffect] = [.journalRemove([a]), .journalPark([entry(1)])]
        let result = EffectExecutor.coalesce(effects)
        // The old entry is replaced first and the new one written; nothing removes it afterwards.
        #expect(result == [.journalRemove([a]), .journalPark([entry(1)])])
    }

    @Test func aWindowParkedAndThenClearedInOneBatchEndsWithoutAnEntry() {
        let a = id(1)
        let result = EffectExecutor.coalesce([.journalPark([entry(1)]), .journalRemove([a])])
        #expect(result == [.journalRemove([a])])
    }

    @Test func aParkForAWindowThatIsClearedInTheSameBatchMovesNothing() {
        let a = id(1)
        let park = FrameRequest(
            id: a, frame: CGRect(x: 5000, y: 5000, width: 10, height: 10), generation: 1, purpose: .park)
        let place = FrameRequest(
            id: id(2), frame: CGRect(x: 0, y: 0, width: 10, height: 10), generation: 1, purpose: .place)
        let result = EffectExecutor.coalesce([
            .journalPark([entry(1)]), .setFrame(park), .setFrame(place), .journalRemove([a]),
        ])
        #expect(result == [.setFrame(place), .journalRemove([a])])
        // A restore for the same window is not a park: it stays.
        let restore = FrameRequest(
            id: a, frame: CGRect(x: 1, y: 1, width: 10, height: 10), generation: 2, purpose: .restore)
        #expect(
            EffectExecutor.coalesce([
                .journalPark([entry(1)]), .setFrame(park), .setFrame(restore), .journalRemove([a]),
            ])
                == [.setFrame(restore), .journalRemove([a])])
    }

    @Test func otherWindowsKeepTheirOwnOperations() {
        let result = EffectExecutor.coalesce([
            .journalPark([entry(1)]), .journalRemove([id(2)]), .journalPark([entry(3)]),
        ])
        #expect(result == [.journalPark([entry(1), entry(3)]), .journalRemove([id(2)])])
    }
}

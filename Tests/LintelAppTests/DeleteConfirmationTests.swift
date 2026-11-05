import AppKit
import Foundation
import LintelKit
import SwiftUI
import Synchronization
import Testing

@testable import LintelApp

/// A clock that only moves when a test advances it, so the 5 s timeout is tested without waiting.
nonisolated final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait, fire, cancel }
                let outcome = state.withLock { state -> Outcome in
                    if Task.isCancelled { return .cancel }
                    if deadline <= state.now { return .fire }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .fire: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers.removeValue(forKey: id) }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// The three list modes whose ⌃X deletes (spec 2026-11-04, step 6.2), each with its own prompt. The source
/// mirrors their actions: Return pastes or copies, ⌃X deletes with a confirmation and keeps the panel open.
nonisolated struct DeletingSource: PanelModeSource {
    static let rows = ["First entry", "Second entry", "Third entry"]
    let mode: String
    let prompt: LocalizedStringResource
    let log: ActionLog

    func search(_ query: NormalizedQuery, filter: PanelModeFilter.ID?, limit: Int) async throws -> [Candidate] {
        Self.rows
            .filter { query.isEmpty || $0.lowercased().contains(query.normalized) }
            .filter { filter == nil || $0.lowercased().hasPrefix(filter ?? "") }
            .map {
                Candidate(
                    itemKey: ItemKey(pluginID: PluginID(rawValue: mode), key: $0), title: $0, icon: .symbol("doc"),
                    match: MatchResult(tier: .fuzzy, score: 0))
            }
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        let log = log
        return [
            ResultAction(id: "\(mode).paste", title: "Paste", symbolName: "doc.on.clipboard") { _ in
                log.record("paste \(candidate.title)")
            },
            ResultAction(
                id: "\(mode).delete", title: "Delete", symbolName: "trash",
                shortcut: KeyShortcut(key: "x", modifiers: .control), keepsPanelOpen: true,
                confirmation: ActionConfirmation(prompt: prompt)
            ) { _ in
                log.record("delete \(candidate.title)")
            },
        ]
    }
}

nonisolated struct DeletingMode: CustomTestStringConvertible, Sendable {
    let id: String
    let prompt: String
    var testDescription: String { id }

    static let all = [
        DeletingMode(id: "clipboard", prompt: "Delete this clipboard entry?"),
        DeletingMode(id: "dictation.history", prompt: "Delete this dictation?"),
        DeletingMode(id: "meetings.library", prompt: "Delete this meeting?"),
    ]
}

@Suite struct DeleteConfirmationTests {
    static let controlX = KeyShortcut(key: "x", modifiers: .control)

    struct Rig {
        let model: PanelModel
        let log: ActionLog
        let clock: ManualClock
        let announced: ActionLog
        let presenter: FakePresenter
    }

    func makeRig(_ mode: DeletingMode = DeletingMode.all[0]) async throws -> Rig {
        let test = try TestEnvironment()
        let coordinator = SearchCoordinator(host: test.makeHost([]), usage: SpyUsageRecorder())
        let clock = ManualClock()
        let model = PanelModel(search: { _ in .empty }, clock: clock)
        let log = ActionLog()
        let panelMode = PanelMode(
            id: PanelModeID(rawValue: mode.id), title: "Mode", symbolName: "doc",
            source: DeletingSource(
                mode: mode.id, prompt: LocalizedStringResource(stringLiteral: mode.prompt), log: log),
            filters: [PanelModeFilter(id: "s", title: "S", symbolName: "s.circle")],
            makePreview: { candidate in AnyView(Text(candidate.title)) })
        model.panelMode = { $0 == panelMode.id ? panelMode : nil }
        model.modeSearch = { mode, text, filter in await coordinator.search(mode: mode, raw: text, filter: filter) }
        let presenter = FakePresenter()
        model.presenter = presenter
        model.panelPresenter = presenter
        let announced = ActionLog()
        model.announce = { announced.record($0) }
        test.tearDown()
        model.show(mode: .plugin(panelMode.id))
        await model.waitForSearch()
        return Rig(model: model, log: log, clock: clock, announced: announced, presenter: presenter)
    }

    // MARK: Per mode

    @Test(arguments: DeletingMode.all)
    func theFirstPressOnlyAsks(_ mode: DeletingMode) async throws {
        let rig = try await makeRig(mode)
        #expect(rig.model.perform(shortcut: Self.controlX))
        await rig.model.waitForAction()
        #expect(rig.log.all.isEmpty)
        let pending = try #require(rig.model.pendingConfirmation)
        #expect(String(localized: pending.prompt) == mode.prompt)
        #expect(pending.hint == "Press ⌃X again to delete")
        #expect(rig.announced.all.last == "\(mode.prompt) Press Control-X again to delete. Escape cancels.")
        #expect(rig.model.isVisible)
    }

    @Test(arguments: DeletingMode.all)
    func theSecondPressDeletesTheSameRowOnce(_ mode: DeletingMode) async throws {
        let rig = try await makeRig(mode)
        rig.model.perform(shortcut: Self.controlX)
        rig.clock.advance(by: .seconds(4))
        #expect(rig.model.perform(shortcut: Self.controlX))
        await rig.model.waitForAction()
        #expect(rig.log.all == ["delete First entry"])
        #expect(rig.model.pendingConfirmation == nil)
        #expect(rig.model.isVisible)
        #expect(rig.presenter.dismissed == 0)
        // The third press asks again: a confirmation is used once.
        rig.model.perform(shortcut: Self.controlX)
        await rig.model.waitForAction()
        #expect(rig.log.all == ["delete First entry"])
        #expect(rig.model.pendingConfirmation != nil)
    }

    @Test(arguments: DeletingMode.all)
    func escCancelsWithoutDeletingOrClearingTheQuery(_ mode: DeletingMode) async throws {
        let rig = try await makeRig(mode)
        rig.model.updateQuery("entry")
        await rig.model.waitForSearch()
        rig.model.perform(shortcut: Self.controlX)
        rig.model.escape()
        #expect(rig.model.pendingConfirmation == nil)
        #expect(rig.model.query == "entry")
        #expect(rig.model.isVisible)
        #expect(rig.announced.all.last == "Cancelled")
        rig.model.perform(shortcut: Self.controlX)
        await rig.model.waitForAction()
        #expect(rig.log.all.isEmpty)
    }

    @Test(arguments: DeletingMode.all)
    func theTimeoutCancels(_ mode: DeletingMode) async throws {
        let rig = try await makeRig(mode)
        rig.model.perform(shortcut: Self.controlX)
        rig.clock.advance(by: PanelModel.confirmationTimeout)
        await rig.model.waitForConfirmationExpiry()
        #expect(rig.model.pendingConfirmation == nil)
        #expect(rig.announced.all.last == "Cancelled")
        rig.model.perform(shortcut: Self.controlX)
        await rig.model.waitForAction()
        #expect(rig.log.all.isEmpty)
        #expect(rig.model.pendingConfirmation != nil)
    }

    // MARK: Cancel paths

    @Test func losingFocusOrHidingCancels() async throws {
        let rig = try await makeRig()
        rig.model.perform(shortcut: Self.controlX)
        rig.model.resignedKey()
        #expect(rig.model.pendingConfirmation == nil)
        rig.model.show(mode: .plugin("clipboard"))
        await rig.model.waitForSearch()
        rig.model.perform(shortcut: Self.controlX)
        await rig.model.waitForAction()
        #expect(rig.log.all.isEmpty)
    }

    @Test func aListReloadCancels() async throws {
        let rig = try await makeRig()
        rig.model.perform(shortcut: Self.controlX)
        rig.model.resultsChanged()
        await rig.model.waitForSearch()
        #expect(rig.model.pendingConfirmation == nil)
        rig.model.perform(shortcut: Self.controlX)
        await rig.model.waitForAction()
        #expect(rig.log.all.isEmpty)
    }

    @Test func aSelectionChangeCancelsAndTheOtherRowAsksOnItsOwn() async throws {
        let rig = try await makeRig()
        rig.model.perform(shortcut: Self.controlX)
        rig.model.moveSelection(by: 1)
        #expect(rig.model.pendingConfirmation == nil)
        rig.model.perform(shortcut: Self.controlX)
        await rig.model.waitForAction()
        #expect(rig.log.all.isEmpty)
        // Moving past the end keeps the selection, so the confirmation stays.
        rig.model.moveSelection(by: 5)
        rig.model.moveSelection(by: 5)
        rig.model.perform(shortcut: Self.controlX)
        #expect(rig.model.pendingConfirmation != nil)
        rig.model.moveSelection(by: 1)
        rig.model.perform(shortcut: Self.controlX)
        await rig.model.waitForAction()
        #expect(rig.log.all == ["delete Third entry"])
    }

    @Test func typingOrAFilterCancels() async throws {
        let rig = try await makeRig()
        rig.model.perform(shortcut: Self.controlX)
        rig.model.updateQuery("f")
        #expect(rig.model.pendingConfirmation == nil)
        await rig.model.waitForSearch()
        rig.model.perform(shortcut: Self.controlX)
        #expect(rig.model.toggleFilter(at: 0))
        #expect(rig.model.pendingConfirmation == nil)
        await rig.model.waitForSearch()
        #expect(rig.log.all.isEmpty)
    }

    @Test func anotherActionCancelsAndRunsItself() async throws {
        let rig = try await makeRig()
        rig.model.perform(shortcut: Self.controlX)
        rig.model.performPrimary()
        await rig.model.waitForAction()
        #expect(rig.log.all == ["paste First entry"])
        #expect(rig.model.pendingConfirmation == nil)
    }

    @Test func aTimeoutFromAnEarlierPromptDoesNotCancelANewOne() async throws {
        let rig = try await makeRig()
        rig.model.perform(shortcut: Self.controlX)
        rig.clock.advance(by: .seconds(3))
        rig.model.moveSelection(by: 1)
        rig.model.perform(shortcut: Self.controlX)
        rig.clock.advance(by: .seconds(3))
        #expect(rig.model.pendingConfirmation != nil)
        rig.model.perform(shortcut: Self.controlX)
        await rig.model.waitForAction()
        #expect(rig.log.all == ["delete Second entry"])
    }

    // MARK: Without a confirmation

    @Test func anActionWithoutAConfirmationRunsAtOnce() async throws {
        let log = ActionLog()
        let (model, _) = try await ListModePanelTests().makeModel(log: log, opened: ActionLog())
        model.show(mode: .plugin("notes"))
        await model.waitForSearch()
        #expect(model.perform(shortcut: Self.controlX))
        await model.waitForAction()
        #expect(log.all.filter { !$0.hasPrefix("search") } == ["delete Zebra note"])
        #expect(model.pendingConfirmation == nil)
    }

    // MARK: View

    @Test func theFooterShowsThePromptWhileItWaits() async throws {
        let rig = try await makeRig(DeletingMode.all[2])
        rig.model.perform(shortcut: Self.controlX)
        let view = LauncherView(model: rig.model, icons: IconCache(loader: { _ in nil }), onFieldCreated: { _ in })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: PanelModel.Metrics.width, height: rig.model.preferredHeight)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > 0)
        #expect(rig.model.preferredHeight == PanelModel.Metrics.maximumHeight)
    }

    @Test func theFooterStringsAreInTheCatalogInEnglishAndPolish() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        let polish = [
            "Press %@ again to delete": "Naciśnij %@ ponownie, aby usunąć",
            "cancels": "anuluje",
            "Escape cancels.": "Escape anuluje.",
            "Cancelled": "Anulowano",
            "Delete this clipboard entry?": "Usunąć ten wpis ze schowka?",
            "Delete this dictation?": "Usunąć to dyktowanie?",
            "Delete this meeting?": "Usunąć to spotkanie?",
        ]
        for (key, expected) in polish {
            let localizations = try #require(strings[key]?["localizations"] as? [String: [String: Any]], "\(key)")
            let pl = localizations["pl"]?["stringUnit"] as? [String: Any]
            let en = localizations["en"]?["stringUnit"] as? [String: Any]
            #expect(pl?["value"] as? String == expected, "\(key)")
            #expect(en?["state"] as? String == "translated", "\(key)")
        }
        #expect(strings["Press ⌃X again to delete this meeting."] == nil)
    }
}

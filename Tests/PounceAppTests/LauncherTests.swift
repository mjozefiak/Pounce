import AppKit
import Carbon.HIToolbox
import Foundation
import PounceKit
import SwiftUI
import Synchronization
import Testing

@testable import PounceApp

// MARK: Fixtures

/// Records what actions ran, from any isolation.
nonisolated final class ActionLog: Sendable {
    private let entries = Mutex<[String]>([])

    var all: [String] { entries.withLock { $0 } }

    func record(_ entry: String) {
        entries.withLock { $0.append(entry) }
    }
}

/// Answers every query with fixed candidates (filtered to those containing the query) and offers two
/// actions per row, the second bound to Command-Return.
nonisolated struct FixedSource: SearchSource {
    let id: SourceID
    let pluginID: PluginID
    let titles: [String]
    let log: ActionLog

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        titles.compactMap { title in
            guard query.isEmpty || title.lowercased().contains(query.normalized) else { return nil }
            return Candidate(
                itemKey: ItemKey(pluginID: pluginID, key: title.lowercased()),
                title: title,
                icon: .symbol("circle"),
                match: MatchResult(tier: .substring, score: 0.5)
            )
        }
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        let log = log
        return [
            ResultAction(id: "open", title: "Open", symbolName: "arrow.up.forward") { context in
                log.record("open \(candidate.title) query=\(context.query?.raw ?? "-")")
            },
            ResultAction(
                id: "reveal",
                title: "Reveal",
                symbolName: "folder",
                shortcut: KeyShortcut(key: "\r", modifiers: .command)
            ) { _ in
                log.record("reveal \(candidate.title)")
            },
            ResultAction(
                id: "copy",
                title: "Copy",
                symbolName: "doc.on.doc",
                shortcut: KeyShortcut(key: "c", modifiers: .command)
            ) { _ in
                log.record("copy \(candidate.title)")
            },
        ]
    }
}

/// Offers one action that throws `error`, like opening an app that was moved since the last scan.
nonisolated struct FailingActionSource: SearchSource {
    let id: SourceID = "fruit.failing"
    let error: any Error & Sendable

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] { [] }

    func actions(for candidate: Candidate) -> [ResultAction] {
        let error = error
        return [ResultAction(id: "open", title: "Open", symbolName: "arrow.up.forward") { _ in throw error }]
    }
}

/// A plugin with three same-tier results, used to test ranking by usage.
final class FruitPlugin: PouncePlugin {
    static let manifest = PluginManifest(id: "fruit", displayName: "Fruit", symbolName: "leaf", order: 5)
    static let log = ActionLog()

    init(context: PluginContext) {}

    var searchSources: [any SearchSource] {
        [FixedSource(id: "fruit.all", pluginID: "fruit", titles: ["Apple", "Apricot", "Banana"], log: Self.log)]
    }
}

/// Fails to start without touching the shared `LifecycleLog` (other suites assert on it in parallel).
final class BrokenPlugin: PouncePlugin {
    static let manifest = PluginManifest(id: "broken", displayName: "Broken", symbolName: "xmark", order: 0)

    init(context: PluginContext) {}

    func activate() async throws { throw TestError.activationFailed }
}

final class FakePresenter: PanelPresenting, PanelPresenter {
    private(set) var presented = 0
    private(set) var dismissed = 0

    func presentPanel() { presented += 1 }
    func dismissPanel() { dismissed += 1 }
    func hidePanel() {}
    func showConfirmation(_ message: LocalizedStringResource) {}
}

private func item(_ title: String, source: FixedSource) -> ResultItem {
    let candidate = Candidate(
        itemKey: ItemKey(pluginID: source.pluginID, key: title.lowercased()),
        title: title,
        icon: .symbol("circle"),
        match: MatchResult(tier: .prefix, score: 1)
    )
    return ResultItem(id: title, candidate: candidate, source: source, kind: "Fruit")
}

private func results(_ query: String, sections: [[String]], source: FixedSource) -> SearchResults {
    SearchResults(
        query: NormalizedQuery(raw: query, normalized: query.lowercased()),
        sections: sections.enumerated().map { index, titles in
            ResultSection(
                id: "s\(index)",
                title: "Fruit",
                symbolName: "leaf",
                kind: .results,
                items: titles.map { item($0, source: source) }
            )
        }
    )
}

// MARK: Symbolic hotkeys and the shortcut policy

@Suite struct SymbolicHotkeysTests {
    private func entry(enabled: Bool, keyCode: Int, flags: Int) -> [String: Any] {
        [
            "enabled": NSNumber(value: enabled),
            "value": [
                "parameters": [NSNumber(value: 32), NSNumber(value: keyCode), NSNumber(value: flags)],
                "type": "standard",
            ],
        ]
    }

    @Test func missingEntriesMeanTheSystemDefaults() {
        #expect(SymbolicHotkeys.occupiedShortcuts(nil) == [.commandSpace, .optionCommandSpace])
        #expect(SymbolicHotkeys.occupiedShortcuts([:]) == [.commandSpace, .optionCommandSpace])
    }

    @Test func enabledSpotlightHoldsItsShortcut() {
        let hotkeys: [String: Any] = [
            "64": entry(enabled: true, keyCode: kVK_Space, flags: 1 << 20),
            "65": entry(enabled: true, keyCode: kVK_Space, flags: (1 << 20) | (1 << 19)),
        ]
        #expect(SymbolicHotkeys.occupiedShortcuts(hotkeys) == [.commandSpace, .optionCommandSpace])
    }

    @Test func disabledOrUnassignedEntriesHoldNothing() {
        let hotkeys: [String: Any] = [
            "64": entry(enabled: false, keyCode: kVK_Space, flags: 1 << 20),
            "65": entry(enabled: true, keyCode: 0xFFFF, flags: 0),
        ]
        #expect(SymbolicHotkeys.occupiedShortcuts(hotkeys).isEmpty)
    }

    @Test func spotlightMovedToAnotherShortcut() {
        let hotkeys: [String: Any] = [
            "64": entry(enabled: true, keyCode: kVK_Space, flags: 1 << 18),
            "65": ["enabled": NSNumber(value: false)],
        ]
        let occupied = SymbolicHotkeys.occupiedShortcuts(hotkeys)
        #expect(occupied == [HotkeyShortcut(carbonKeyCode: kVK_Space, carbonModifiers: controlKey)])
        #expect(ShortcutPolicy.defaultShortcut(occupied: occupied) == .commandSpace)
    }

    @Test func enabledEntryWithoutParametersUsesTheDefault() {
        let hotkeys: [String: Any] = [
            "64": ["enabled": NSNumber(value: true)], "65": ["enabled": NSNumber(value: false)],
        ]
        #expect(SymbolicHotkeys.occupiedShortcuts(hotkeys) == [.commandSpace])
    }

    @Test func eventFlagsConvertToCarbonModifiers() {
        let flags = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
        #expect(HotkeyShortcut.carbonModifiers(fromEventFlags: flags) == shiftKey | controlKey | optionKey | cmdKey)
        #expect(HotkeyShortcut.commandSpace.displayString == "⌘Space")
        #expect(HotkeyShortcut.controlOptionSpace.displayString == "⌃⌥Space")
    }

    @Test func pluginShortcutsMapToCarbon() throws {
        let shortcut = try #require(HotkeyShortcut(KeyShortcut(key: "V", modifiers: [.command, .shift])))
        #expect(shortcut == HotkeyShortcut(carbonKeyCode: kVK_ANSI_V, carbonModifiers: cmdKey | shiftKey))
        #expect(shortcut.displayString == "⇧⌘V")
        #expect(HotkeyShortcut(KeyShortcut(key: "é")) == nil)
    }
}

@Suite struct HotkeyServiceTests {
    /// The registrar, settings and a mutable set of occupied shortcuts for one service.
    final class Rig {
        let registrar = InMemoryHotkeyRegistrar()
        let settings = InMemorySettingsStore()
        var occupied: Set<HotkeyShortcut>
        lazy var service = HotkeyService(registrar: registrar, settings: settings) { [unowned self] in
            self.occupied
        }

        init(occupied: Set<HotkeyShortcut>) {
            self.occupied = occupied
        }
    }

    @Test func defaultsToCommandSpaceWhenItIsFree() {
        let rig = Rig(occupied: [.optionCommandSpace])
        rig.service.start {}
        #expect(rig.service.mainShortcut == .commandSpace)
        #expect(!rig.service.spotlightHoldsCommandSpace)
        #expect(rig.registrar.handlers[.main] != nil)
    }

    @Test func fallsBackToControlOptionSpaceAndSwitchesWhenSpotlightLetsGo() {
        let rig = Rig(occupied: [.commandSpace, .optionCommandSpace])
        rig.service.start {}
        #expect(rig.service.mainShortcut == .controlOptionSpace)
        #expect(rig.service.spotlightHoldsCommandSpace)

        rig.occupied = [.optionCommandSpace]
        rig.service.refreshDefault()
        #expect(rig.service.mainShortcut == .commandSpace)
        #expect(!rig.service.spotlightHoldsCommandSpace)
    }

    @Test func aUserChosenShortcutAlwaysWins() {
        let rig = Rig(occupied: [.commandSpace])
        rig.service.start {}
        let custom = HotkeyShortcut(carbonKeyCode: kVK_ANSI_K, carbonModifiers: cmdKey | optionKey)
        rig.registrar.setShortcut(custom, for: .main)
        rig.service.userRecordedMainShortcut()
        #expect(rig.service.isUserDefined)

        rig.occupied = []
        rig.service.refreshDefault()
        #expect(rig.service.mainShortcut == custom)

        // Clearing the recorder is a choice too: no shortcut stays no shortcut.
        rig.registrar.setShortcut(nil, for: .main)
        rig.service.userRecordedMainShortcut()
        rig.service.refreshDefault()
        #expect(rig.service.mainShortcut == nil)

        rig.service.resetToDefault()
        #expect(!rig.service.isUserDefined)
        #expect(rig.service.mainShortcut == .commandSpace)
    }

    @Test func commandShortcutsApplyTheirDefaultOnceAndFollowThePlugins() {
        let rig = Rig(occupied: [])
        let command = PluginCommand(
            id: "clipboard.history",
            title: "Clipboard History",
            defaultShortcut: KeyShortcut(key: "v", modifiers: [.command, .shift])
        )
        rig.service.syncCommands([command]) { _ in }
        let name = HotkeyName.command("clipboard.history")
        #expect(
            rig.registrar.shortcuts[name]
                == HotkeyShortcut(carbonKeyCode: kVK_ANSI_V, carbonModifiers: cmdKey | shiftKey))
        #expect(rig.registrar.handlers[name] != nil)

        // The user cleared it; a later sync keeps it cleared.
        rig.registrar.setShortcut(nil, for: name)
        rig.service.syncCommands([command]) { _ in }
        #expect(rig.registrar.shortcuts[name] == nil)

        // The plugin was turned off: its handler goes away.
        rig.service.syncCommands([]) { _ in }
        #expect(rig.registrar.handlers[name] == nil)
    }

    @Test func commandNamesAreValidShortcutNames() {
        #expect(HotkeyName.main.rawValue == "mainHotkey")
        #expect(HotkeyName.command("clipboard.history").rawValue == "command_clipboard_history")
    }
}

// MARK: Panel

@Suite struct PanelModelTests {
    let source = FixedSource(id: "fruit.all", pluginID: "fruit", titles: [], log: ActionLog())

    private func makeModel(sections: [[String]] = [["Apple", "Apricot"], ["Banana"]]) -> (PanelModel, FakePresenter) {
        let source = source
        let model = PanelModel { query in results(query, sections: sections, source: source) }
        let presenter = FakePresenter()
        model.presenter = presenter
        model.panelPresenter = presenter
        model.announce = { _ in }
        return (model, presenter)
    }

    @Test func showsSearchesAndHidesResettingTheQuery() async {
        let (model, presenter) = makeModel()
        model.show()
        #expect(model.isVisible)
        #expect(presenter.presented == 1)
        model.updateQuery("ap")
        await model.waitForSearch()
        #expect(model.results.items.count == 3)
        #expect(model.selectedIndex == 0)

        model.hide()
        #expect(!model.isVisible)
        #expect(presenter.dismissed == 1)
        #expect(model.query.isEmpty)
        #expect(model.results.sections.isEmpty)
    }

    @Test func escapeClearsTheQueryThenCloses() async {
        let (model, _) = makeModel()
        model.show()
        model.updateQuery("ap")
        await model.waitForSearch()
        model.escape()
        #expect(model.isVisible)
        #expect(model.query.isEmpty)
        model.escape()
        #expect(!model.isVisible)
    }

    @Test func losingFocusOrTheMainShortcutCloses() {
        let (model, _) = makeModel()
        model.show()
        model.resignedKey()
        #expect(!model.isVisible)
        model.toggle()
        #expect(model.isVisible)
        model.toggle()
        #expect(!model.isVisible)
    }

    @Test func selectionCrossesSectionsAndStopsAtTheEnds() async {
        let (model, _) = makeModel()
        var announcements: [String] = []
        model.announce = { announcements.append($0) }
        model.show()
        model.updateQuery("a")
        await model.waitForSearch()
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        #expect(model.selectedItem?.candidate.title == "Banana")
        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 2)
        model.moveSelection(by: -5)
        #expect(model.selectedIndex == 0)
        #expect(announcements.first?.hasPrefix("Apricot") == true)
    }

    @Test func returnRunsTheFirstActionWithTheQueryAndHidesFirst() async throws {
        let log = ActionLog()
        let source = FixedSource(id: "fruit.all", pluginID: "fruit", titles: [], log: log)
        let model = PanelModel { query in results(query, sections: [["Apple"]], source: source) }
        let presenter = FakePresenter()
        model.presenter = presenter
        model.panelPresenter = presenter
        model.announce = { _ in }
        model.show()
        model.updateQuery("Ap")
        await model.waitForSearch()

        model.performPrimary()
        #expect(!model.isVisible)
        try await waitUntil { log.all.count == 1 }
        #expect(log.all == ["open Apple query=Ap"])

        model.show()
        model.updateQuery("Ap")
        await model.waitForSearch()
        model.performSecondary()
        model.show()
        model.updateQuery("Ap")
        await model.waitForSearch()
        #expect(model.perform(shortcut: KeyShortcut(key: "c", modifiers: .command)))
        #expect(!model.perform(shortcut: KeyShortcut(key: "x", modifiers: .command)))
        try await waitUntil { log.all.count == 3 }
        #expect(log.all.sorted() == ["copy Apple", "open Apple query=Ap", "reveal Apple"])
    }

    @Test func aFailedActionReopensThePanelWithAMessageUntilTheNextKeystroke() async {
        let failing = FailingActionSource(error: CocoaError(.fileNoSuchFile))
        let model = PanelModel { query in
            let candidate = Candidate(
                itemKey: ItemKey(pluginID: "fruit", key: "apple"),
                title: "Apple",
                icon: .symbol("circle"),
                match: MatchResult(tier: .prefix, score: 1)
            )
            let row = ResultItem(id: "apple", candidate: candidate, source: failing, kind: "Fruit")
            return SearchResults(
                query: NormalizedQuery(raw: query, normalized: query.lowercased()),
                sections: [ResultSection(id: "s", title: "Fruit", symbolName: "leaf", kind: .results, items: [row])]
            )
        }
        let presenter = FakePresenter()
        model.presenter = presenter
        model.panelPresenter = presenter
        var announcements: [String] = []
        model.announce = { announcements.append($0) }
        model.show()
        model.updateQuery("ap")
        await model.waitForSearch()

        model.performPrimary()
        await model.waitForAction()

        #expect(model.isVisible)
        #expect(presenter.presented == 2)
        #expect(model.errorMessage?.contains("Apple") == true)
        #expect(announcements.last == model.errorMessage)
        #expect(model.showsResultsArea)
        #expect(model.preferredHeight > PanelModel.Metrics.fieldHeight)

        model.updateQuery("a")
        #expect(model.errorMessage == nil)
    }

    @Test func aCancelledActionIsNotReported() async {
        let failing = FailingActionSource(error: CocoaError(.userCancelled))
        let model = PanelModel { query in
            let candidate = Candidate(
                itemKey: ItemKey(pluginID: "fruit", key: "apple"),
                title: "Apple",
                icon: .symbol("circle"),
                match: MatchResult(tier: .prefix, score: 1)
            )
            let row = ResultItem(id: "apple", candidate: candidate, source: failing, kind: "Fruit")
            return SearchResults(
                query: NormalizedQuery(raw: query, normalized: query.lowercased()),
                sections: [ResultSection(id: "s", title: "Fruit", symbolName: "leaf", kind: .results, items: [row])]
            )
        }
        let presenter = FakePresenter()
        model.presenter = presenter
        model.panelPresenter = presenter
        model.announce = { _ in }
        model.show()
        model.updateQuery("ap")
        await model.waitForSearch()

        model.performPrimary()
        await model.waitForAction()

        #expect(!model.isVisible)
        #expect(model.errorMessage == nil)
        #expect(PanelModel.isCancellation(CancellationError()))
    }

    @Test func changedResultsSearchAgainKeepingTheSelection() async {
        let titles = Mutex(["Apple"])
        let source = source
        let model = PanelModel { query in
            results(query, sections: [titles.withLock { $0 }], source: source)
        }
        model.presenter = FakePresenter()
        model.announce = { _ in }
        model.resultsChanged()
        #expect(model.results.items.isEmpty)

        model.show()
        model.updateQuery("a")
        await model.waitForSearch()
        #expect(model.results.items.map(\.candidate.title) == ["Apple"])

        titles.withLock { $0 = ["Apricot", "Apple"] }
        model.resultsChanged()
        await model.waitForSearch()
        #expect(model.results.items.map(\.candidate.title) == ["Apricot", "Apple"])
        #expect(model.selectedItem?.candidate.title == "Apple")
    }

    @Test func heightGrowsWithResultsUpToTheMaximum() async {
        let (empty, _) = makeModel(sections: [])
        empty.show()
        await empty.waitForSearch()
        #expect(empty.preferredHeight == PanelModel.Metrics.fieldHeight)
        empty.updateQuery("zzz")
        await empty.waitForSearch()
        #expect(empty.showsNoResults)
        #expect(empty.preferredHeight > PanelModel.Metrics.fieldHeight)

        let many = (0..<40).map { "Item \($0)" }
        let (full, _) = makeModel(sections: [many])
        full.show()
        full.updateQuery("item")
        await full.waitForSearch()
        #expect(full.preferredHeight == PanelModel.Metrics.maximumHeight)
    }

    @Test func listViewRendersTheResultsAndCreatesTheField() async {
        let (model, _) = makeModel()
        model.show()
        model.updateQuery("a")
        await model.waitForSearch()
        var field: NSTextField?
        let view = LauncherView(
            model: model,
            icons: IconCache(loader: { _ in nil }),
            modeView: { _ in nil },
            onFieldCreated: { field = $0 }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: PanelModel.Metrics.width, height: model.preferredHeight)
        hosting.layoutSubtreeIfNeeded()
        #expect(field != nil)
        #expect(field?.stringValue == "a")
        #expect(hosting.fittingSize.width > 0)
    }

    @Test func panelSitsInTheUpperPartOfTheScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let frame = PanelGeometry.frame(height: 56, width: 760, visibleFrame: visible)
        #expect(frame.midX == visible.midX)
        #expect(frame.maxY == visible.maxY - visible.height / 4)
    }
}

/// Polls a condition the main actor updates from a task.
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

// MARK: Search coordinator

@Suite(.serialized) struct SearchCoordinatorTests {
    @Test func ranksByUsageWithinASectionAndShowsFailedPlugins() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([FruitPlugin.self, BrokenPlugin.self])
        await host.start()
        let usage = test.environment.usage
        try await usage.recordUse(of: ItemKey(pluginID: "fruit", key: "apricot"), queryPrefix: "ap", at: Date())
        let coordinator = SearchCoordinator(host: host, usage: usage)

        let found = try #require(await coordinator.search("ap"))
        #expect(found.sections.map(\.kind) == [.unavailable("broken"), .results])
        #expect(found.items.map(\.candidate.title) == ["Apricot", "Apple"])
        await host.stop()
    }

    @Test func anEmptyQueryShowsRecentlyUsedItems() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([FruitPlugin.self])
        await host.start()
        let usage = test.environment.usage
        try await usage.recordUse(of: ItemKey(pluginID: "fruit", key: "banana"), queryPrefix: nil, at: Date())
        let coordinator = SearchCoordinator(host: host, usage: usage)

        let found = try #require(await coordinator.search(""))
        #expect(found.sections.map(\.kind) == [.recent])
        #expect(found.items.map(\.candidate.title) == ["Banana"])
        await host.stop()
    }
}

// MARK: Shell pieces

/// Records whether the window was asked to close, and refuses so nothing appears on screen.
final class CloseRecorder: NSObject, NSWindowDelegate {
    private(set) var asked = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        asked += 1
        return false
    }
}

@Suite struct ShellWindowTests {
    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_W)
        )
    }

    @Test func commandWClosesSettingsAndOnboardingWindows() throws {
        let window = ShellWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let recorder = CloseRecorder()
        window.delegate = recorder

        #expect(window.performKeyEquivalent(with: try #require(key("w", .command, window: window))))
        #expect(recorder.asked == 1)
        #expect(!ShellWindow.isClose(try #require(key("w", [.command, .shift], window: window))))
        #expect(!ShellWindow.isClose(try #require(key("q", .command, window: window))))
    }

    @Test func recordersAreReadOnlyWithoutGlobalHotkeys() {
        let settings = InMemorySettingsStore()
        let live = HotkeyService(registrar: InMemoryHotkeyRegistrar(), settings: settings, readOccupied: { [] })
        let qa = HotkeyService(
            registrar: InMemoryHotkeyRegistrar(), settings: settings, readOccupied: { [] }, allowsRecording: false)
        #expect(live.allowsRecording)
        #expect(!qa.allowsRecording)
    }
}

@Suite struct ShellPhase1Tests {
    @Test func menuWithShellActionsOpensThePanelAndSettings() {
        let menu = NSMenu()
        let actions = ShellMenuActions(
            openPanel: {},
            openSettings: {},
            mainShortcut: { .commandSpace },
            runCommand: { _ in }
        )
        StatusMenuBuilder(actions: actions).populate(menu, commands: [])
        #expect(menu.items.map(\.title) == ["Open Pounce", "", "Settings…", "About Pounce", "", "Quit Pounce"])
        #expect(menu.items[0].keyEquivalent == " ")
        #expect(menu.items[0].keyEquivalentModifierMask == .command)
        #expect(menu.items[2].keyEquivalent == ",")
    }

    @Test func openingAnAppYieldsActivationWithoutTouchingRecentsOptions() {
        let configuration = SystemWorkspaceClient.configuration(
            for: ApplicationOpenOptions(addsToRecentItems: false, yieldsActivationTo: "com.apple.TextEdit")
        )
        #expect(configuration.activates)
        #expect(!configuration.addsToRecentItems)
        #expect(configuration.promptsUserIfNeeded)
    }

    @Test func iconsLoadOffTheMainThread() async throws {
        let before = IconLoader.mainThreadLoads.withLock { $0 }
        let cache = IconCache(diskDirectory: nil)
        let image = await cache.image(for: .symbol("star"))
        #expect(image != nil)
        #expect(cache.cached(.symbol("star")) != nil)
        #expect(IconLoader.mainThreadLoads.withLock { $0 } == before)
    }

    @Test func appIconsAreCachedOnDiskByPathAndDate() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pounce-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = URL(filePath: "/System/Applications/Calculator.app", directoryHint: .isDirectory)
        let first = IconLoader.diskCacheURL(for: app, in: directory)
        #expect(first != nil)
        #expect(first == IconLoader.diskCacheURL(for: app, in: directory))
        #expect(IconLoader.diskCacheURL(for: directory.appending(path: "missing.app"), in: directory) == nil)
    }

    @Test func appSettingsPersistUnderTheirKeys() {
        let store = InMemorySettingsStore()
        let settings = AppSettings(store: store)
        #expect(settings.textSize == .medium)
        #expect(settings.panelLevel == .floating)
        #expect(!settings.shortcutOnboardingCompleted)

        settings.textSize = .large
        settings.shortcutOnboardingCompleted = true
        store.setValue(.string("statusBar"), forKey: "app.panelLevel")
        #expect(store.value(forKey: "app.textSize") == .string("l"))
        #expect(store.value(forKey: "app.onboarding.shortcutCompleted") == .bool(true))

        let reloaded = AppSettings(store: store)
        #expect(reloaded.textSize == .large)
        #expect(reloaded.panelLevel == .statusBar)
        #expect(reloaded.shortcutOnboardingCompleted)
    }

    @Test func textSizesScaleFromMedium() {
        #expect(TextSize.default == .medium)
        #expect(TextSize.allCases.map(\.scale) == [0.9, 1, 1.15, 1.3])
    }
}

#if DEBUG
@Suite struct QAPanelOptionsTests {
    @Test func parsesThePanelAndSettingsOptions() throws {
        let options = try #require(
            try QAOptions.parse([
                "Pounce", "--qa-panel", "search", "--qa-query", "Te", "--qa-settings", "features",
                "--qa-onboarding", "--qa-spotlight", "on", "--qa-setting", "plugins.apps.spotlight=false",
                "--qa-setting", "plugins.apps.roots=/tmp/apps", "--qa-setting", "app.panelLevel=statusBar",
                "--qa-record-use", "apps:com.apple.TextEdit",
            ])
        )
        #expect(options.panelMode == "search")
        #expect(options.query == "Te")
        #expect(options.settingsPane == "features")
        #expect(options.showsOnboarding)
        #expect(options.spotlightHoldsCommandSpace == true)
        #expect(options.settings["plugins.apps.spotlight"] == .bool(false))
        #expect(options.settings["plugins.apps.roots"] == .string("/tmp/apps"))
        #expect(options.recordedUses == ["apps:com.apple.TextEdit"])
    }

    @Test func rejectsABadSpotlightValue() {
        #expect(throws: QAOptions.ParseError.invalidValue("--qa-spotlight", "maybe")) {
            _ = try QAOptions.parse(["--qa-spotlight", "maybe"])
        }
        #expect(throws: QAOptions.ParseError.invalidValue("--qa-setting", "novalue")) {
            _ = try QAOptions.parse(["--qa-setting", "novalue"])
        }
    }

    @Test func qaSettingsSeedTheInMemoryStore() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pounce-qa-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var options = QAOptions(dataRoot: root)
        options.settings = ["plugins.apps.spotlight": .bool(false)]
        let environment = try AppEnvironment.qa(options)
        #expect(environment.settings.value(forKey: "plugins.apps.spotlight") == .bool(false))
        #expect(environment.cachesRoot.path.hasPrefix(root.path))
    }
}
#endif

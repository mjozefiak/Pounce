import AppKit
import Foundation
import PounceCore
import PounceKit
import Testing

@testable import ClipboardPlugin

/// An entry copied a few minutes ago: the plugin's retention job deletes anything older than 30 days as
/// soon as it activates.
func fresh(_ text: String, kind: ClipKind = .text, minutesAgo: Double = 0) -> ClipDraft {
    draft(text, kind: kind, at: Date().addingTimeInterval(-minutesAgo * 60))
}

@Suite("ClipboardPlugin lifecycle")
@MainActor
struct ClipboardPluginLifecycleTests {
    @Test func activationCreatesTheKeyAndRecords() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        #expect(harness.keychain.storedKeyCount == 1)
        #expect(harness.plugin.state.availability == .ready)
        #expect(harness.plugin.isWatching)
        #expect(!harness.plugin.state.historyWasReset)
        await harness.tearDown()
        #expect(harness.plugin.state.availability == .inactive)
        #expect(!harness.plugin.isWatching)
    }

    @Test func storageIsPrivate() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let directory = harness.directory.url.appending(path: "Plugins/clipboard", directoryHint: .isDirectory)
        let database = directory.appending(path: "clipboard.sqlite")
        let attributes = try FileManager.default.attributesOfItem(atPath: database.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let blobs = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: "blobs").path)
        #expect((blobs[.posixPermissions] as? Int) == 0o700)
        await harness.tearDown()
    }

    @Test func aLockedKeychainDisablesHistoryWithoutDeletingAnything() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        await harness.plugin.deactivate()
        harness.keychain.state.withLock { $0.readError = .interactionNotAllowed }

        try await harness.plugin.activate()
        #expect(harness.plugin.state.availability == .keychainLocked)
        #expect(!harness.plugin.isWatching)
        #expect(harness.keychain.storedKeyCount == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: harness.directory.url.appending(path: "Plugins/clipboard/clipboard.sqlite").path))
        #expect(ClipboardBanner.banners(for: harness.plugin.state).first == .keychainLocked)

        // Unlocking and retrying (session activation, opening the mode or "Try Again") opens the history.
        harness.keychain.state.withLock { $0.readError = nil }
        harness.plugin.retryIfUnavailable()
        #expect(harness.plugin.state.availability == .ready)
        #expect(harness.plugin.isWatching)
        await harness.tearDown()
    }

    @Test func aMissingKeyResetsTheHistoryAndShowsTheNotice() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        await harness.plugin.deactivate()
        harness.keychain.state.withLock { $0.items = [:] }

        try await harness.plugin.activate()
        #expect(harness.plugin.state.availability == .ready)
        #expect(harness.plugin.state.historyWasReset)
        #expect(harness.settings.value(forKey: "plugins.clipboard.historyResetNotice") == .bool(true))
        #expect(ClipboardBanner.banners(for: harness.plugin.state).contains(.historyReset))
        await harness.tearDown()
    }

    @Test func pausingStopsTheWatcherAndResumingRestartsIt() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        harness.plugin.settings.setPaused(true)
        #expect(!harness.plugin.isWatching)
        #expect(harness.plugin.state.isPaused)
        #expect(harness.settings.value(forKey: "plugins.clipboard.paused") == .bool(true))
        let pauseTitle = harness.plugin.commands.first { $0.id == ClipboardPlugin.pauseCommandID }?.title.key
        #expect(pauseTitle == "Resume Clipboard Recording")

        harness.plugin.settings.setPaused(false)
        #expect(harness.plugin.isWatching)
        await harness.tearDown()
    }

    @Test func thePauseMenuCommandToggles() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let pause = try #require(harness.plugin.commands.first { $0.id == ClipboardPlugin.pauseCommandID })
        await pause.run()
        #expect(harness.plugin.settings.isPaused)
        #expect(!harness.plugin.isWatching)
        await harness.tearDown()
    }

    @Test(arguments: [PasteboardAccess.ask, .alwaysDeny])
    func pasteboardAccessThatWouldPromptOrFailStopsRecording(_ access: PasteboardAccess) async throws {
        let harness = try PluginHarness()
        harness.pasteboard.access = access
        try await harness.plugin.activate()
        #expect(!harness.plugin.isWatching)
        #expect(!harness.plugin.state.isRecording)
        let banners = ClipboardBanner.banners(for: harness.plugin.state)
        #expect(banners.contains(access == .ask ? .accessAsks : .accessDenied))
        await harness.tearDown()
    }

    @Test func aStartedWatcherIgnoresWhatWasAlreadyOnThePasteboard() async throws {
        let harness = try PluginHarness()
        harness.pasteboard.setString("before Pounce started")
        try await harness.plugin.activate()
        let watcher = try #require(harness.plugin.watcher)
        #expect(!watcher.check())
        await harness.tearDown()
    }

    @Test func aCopyIsStoredAndSignalled() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let watcher = try #require(harness.plugin.watcher)
        harness.pasteboard.setString("fake copied text")
        #expect(watcher.check())
        let source = harness.plugin.searchSource
        let stored = await eventually {
            (try? await source.search(TextNormalizer.query(""), filter: nil, limit: 10).count) == 1
        }
        #expect(stored)
        #expect(harness.changes.value >= 1)
        #expect(await eventually { harness.plugin.state.entryCount == 1 })
        await harness.tearDown()
    }

    @Test func ignoredAppsAreNotRecorded() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        harness.workspace.frontmost = RunningApplication(
            processIdentifier: 777, bundleIdentifier: "com.apple.Passwords", name: "Passwords")
        harness.pasteboard.setString("fake secret")
        let watcher = try #require(harness.plugin.watcher)
        watcher.check()
        #expect(watcher.lastEvent == .skipped(.ignoredApp))
        #expect(try harness.plugin.store?.count() == 0)
        await harness.tearDown()
    }

    @Test func eraseDataDeletesTheKey() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        await harness.plugin.deactivate()
        try await harness.plugin.eraseData()
        #expect(harness.keychain.storedKeyCount == 0)
        await harness.tearDown()
    }

    @Test func clearHistoryEmptiesTheStore() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let store = try #require(harness.plugin.store)
        try store.insert(fresh("one"))
        try store.insert(fresh("two", minutesAgo: 1))
        #expect(await harness.plugin.clearHistory())
        #expect(try store.count() == 0)
        await harness.tearDown()
    }

    @Test func clipboardNeverTouchesRankingDatabase() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let store = try #require(harness.plugin.store)
        try store.insert(fresh("hello"))
        let panel = FakePanel()
        let candidates = try await harness.plugin.searchSource.search(
            TextNormalizer.query("hel"), filter: nil, limit: 10)
        let candidate = try #require(candidates.first)
        #expect(candidate.itemKey.pluginID == "clipboard")
        try await harness.plugin.searchSource.actions(for: candidate)[1].perform(harness.actionContext(panel))
        #expect(harness.usage.callCount == 0)
        await harness.tearDown()
    }

    @Test func commandsAndModeAreContributed() throws {
        let harness = try PluginHarness()
        let history = try #require(harness.plugin.commands.first { $0.id == ClipboardPlugin.historyCommandID })
        #expect(history.panelMode == ClipboardPlugin.modeID)
        #expect(history.defaultShortcut == KeyShortcut(key: "v", modifiers: [.command, .shift]))
        let mode = try #require(harness.plugin.panelModes.first)
        #expect(mode.isListMode)
        #expect(mode.filters.map(\.id) == ["text", "rich", "image", "file", "url"])
        #expect(harness.plugin.onboardingSteps.map(\.id) == [ClipboardPlugin.onboardingStepID])
        #expect(harness.plugin.requiredPermissions == [.accessibility, .pasteboard])
        #expect(harness.plugin.settingsPane() != nil)
    }
}

@Suite("Clipboard search source")
@MainActor
struct ClipboardSearchSourceTests {
    private func harness(with texts: [(String, ClipKind)]) async throws -> PluginHarness {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let store = try #require(harness.plugin.store)
        for (index, (text, kind)) in texts.enumerated() {
            try store.insert(fresh(text, kind: kind, minutesAgo: Double(texts.count - index)))
        }
        return harness
    }

    @Test func anEmptyQueryListsNewestFirst() async throws {
        let harness = try await harness(with: [("first", .text), ("second", .text), ("third", .url)])
        let results = try await harness.plugin.searchSource.search(TextNormalizer.query(""), filter: nil, limit: 10)
        #expect(results.map(\.title) == ["third", "second", "first"])
        await harness.tearDown()
    }

    @Test func aFilterKeepsOneKind() async throws {
        let harness = try await harness(with: [("plain", .text), ("https://example.com", .url)])
        let results = try await harness.plugin.searchSource.search(TextNormalizer.query(""), filter: "url", limit: 10)
        #expect(results.map(\.title) == ["https://example.com"])
        await harness.tearDown()
    }

    @Test func aQueryMatchesTitlesFuzzily() async throws {
        let harness = try await harness(with: [("Quarterly report draft", .text), ("grocery list", .text)])
        let results = try await harness.plugin.searchSource.search(TextNormalizer.query("qrd"), filter: nil, limit: 10)
        #expect(results.first?.title == "Quarterly report draft")
        #expect(!results.contains { $0.title == "grocery list" })
        await harness.tearDown()
    }

    @Test func fullTextFindsWordsBeyondTheFirstLine() async throws {
        let harness = try await harness(with: [("Title line\nthe body mentions zanzibar", .text)])
        let results = try await harness.plugin.searchSource.search(
            TextNormalizer.query("zanzibar"), filter: nil, limit: 10)
        #expect(results.map(\.title) == ["Title line"])
        await harness.tearDown()
    }

    @Test func returnPastesWhenAccessibilityIsGrantedAndCopiesOtherwise() async throws {
        let harness = try await harness(with: [("entry", .text)])
        let source = harness.plugin.searchSource
        let candidate = try #require(try await source.search(TextNormalizer.query(""), filter: nil, limit: 1).first)
        #expect(source.actions(for: candidate).map(\.id) == ["clipboard.paste", "clipboard.copy", "clipboard.delete"])
        #expect(source.actions(for: candidate).first?.title.key == "Paste")

        harness.permissions.accessibility = .denied
        harness.plugin.refreshEnvironment()
        #expect(source.actions(for: candidate).first?.title.key == "Copy")
        await harness.tearDown()
    }

    @Test func deleteKeepsThePanelOpenAndRemovesTheEntry() async throws {
        let harness = try await harness(with: [("keep", .text), ("remove", .text)])
        let source = harness.plugin.searchSource
        let candidates = try await source.search(TextNormalizer.query(""), filter: nil, limit: 10)
        let remove = try #require(candidates.first { $0.title == "remove" })
        let delete = try #require(source.actions(for: remove).last)
        #expect(delete.keepsPanelOpen)
        #expect(delete.shortcut == KeyShortcut(key: "x", modifiers: .control))
        try await delete.perform(harness.actionContext(FakePanel()))
        let after = try await source.search(TextNormalizer.query(""), filter: nil, limit: 10)
        #expect(after.map(\.title) == ["keep"])
        await harness.tearDown()
    }

    @Test func noHistoryMeansNoResults() async throws {
        let harness = try PluginHarness()
        let results = try await harness.plugin.searchSource.search(TextNormalizer.query(""), filter: nil, limit: 10)
        #expect(results.isEmpty)
    }
}

@Suite("Paste service")
@MainActor
struct PasteServiceTests {
    @Test(arguments: [
        (true, true, PasteDecision.paste),
        (false, true, .copyOnly(.noAccessibility)),
        (true, false, .copyOnly(.targetGone)),
        (false, false, .copyOnly(.noAccessibility)),
    ])
    func decision(accessibility: Bool, targetRunning: Bool, expected: PasteDecision) {
        #expect(PasteDecision.decide(accessibilityGranted: accessibility, targetRunning: targetRunning) == expected)
    }

    private func prepared() async throws -> (PluginHarness, Candidate) {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let store = try #require(harness.plugin.store)
        try store.insert(fresh("fake pasted text"))
        let candidate = try #require(
            try await harness.plugin.searchSource.search(TextNormalizer.query(""), filter: nil, limit: 1).first)
        return (harness, candidate)
    }

    @Test func pasteWritesThePasteboardAndPostsCommandV() async throws {
        let (harness, candidate) = try await prepared()
        let panel = FakePanel()
        try await harness.plugin.searchSource.actions(for: candidate)[0].perform(harness.actionContext(panel))
        #expect(harness.pasteboard.string() == "fake pasted text")
        #expect(harness.events.posts == 1)
        #expect(panel.confirmations.isEmpty)
        // Pounce's own write is not recorded again (the running watcher may have polled already).
        let watcher = try #require(harness.plugin.watcher)
        watcher.check()
        #expect(watcher.lastEvent == .ownWrite)
        #expect(try harness.plugin.store?.count() == 1)
        await harness.tearDown()
    }

    @Test func withoutAccessibilityReturnOnlyCopies() async throws {
        let (harness, candidate) = try await prepared()
        harness.permissions.accessibility = .denied
        let panel = FakePanel()
        try await harness.plugin.searchSource.actions(for: candidate)[0].perform(harness.actionContext(panel))
        #expect(harness.pasteboard.string() == "fake pasted text")
        #expect(harness.events.posts == 0)
        #expect(panel.confirmations == ["Copied. Allow Accessibility to paste."])
        await harness.tearDown()
    }

    @Test func secureEventInputFallsBackToCopy() async throws {
        let (harness, candidate) = try await prepared()
        harness.events.error = .secureEventInput
        let panel = FakePanel()
        try await harness.plugin.searchSource.actions(for: candidate)[0].perform(harness.actionContext(panel))
        #expect(harness.pasteboard.string() == "fake pasted text")
        #expect(panel.confirmations == ["Copied"])
        await harness.tearDown()
    }

    @Test func aQuitTargetAppFallsBackToCopy() async throws {
        let (harness, candidate) = try await prepared()
        let panel = FakePanel()
        try await harness.plugin.searchSource.actions(for: candidate)[0].perform(
            harness.actionContext(panel, previousApp: 9999))
        #expect(harness.events.posts == 0)
        #expect(panel.confirmations == ["Copied"])
        await harness.tearDown()
    }

    @Test func copyOnlyNeverPosts() async throws {
        let (harness, candidate) = try await prepared()
        let panel = FakePanel()
        try await harness.plugin.searchSource.actions(for: candidate)[1].perform(harness.actionContext(panel))
        #expect(harness.events.posts == 0)
        #expect(harness.pasteboard.string() == "fake pasted text")
        #expect(panel.confirmations == ["Copied"])
        await harness.tearDown()
    }

    @Test func pastingMovesTheEntryToTheTop() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let store = try #require(harness.plugin.store)
        try store.insert(fresh("older", minutesAgo: 10))
        try store.insert(fresh("newer", minutesAgo: 5))
        let source = harness.plugin.searchSource
        let older = try #require(
            try await source.search(TextNormalizer.query(""), filter: nil, limit: 10).first { $0.title == "older" })
        try await source.actions(for: older)[1].perform(harness.actionContext(FakePanel()))
        let moved = await eventually {
            (try? await source.search(TextNormalizer.query(""), filter: nil, limit: 10).first?.title) == "older"
        }
        #expect(moved)
        await harness.tearDown()
    }
}

@Suite("Clipboard views")
@MainActor
struct ClipboardViewTests {
    @Test func bannersFollowTheState() {
        let state = ClipboardState()
        state.availability = .ready
        state.pasteAllowed = true
        #expect(ClipboardBanner.banners(for: state).isEmpty)
        state.isPaused = true
        state.pasteAllowed = false
        #expect(ClipboardBanner.banners(for: state) == [.paused, .pasteDisabled])
        state.availability = .keychainUnavailable
        state.access = .alwaysDeny
        #expect(ClipboardBanner.banners(for: state).prefix(2) == [.keychainUnavailable, .accessDenied])
    }

    @Test func previewFindsTheImageAndFilePaths() throws {
        let summary = ClipSummary(
            id: 1, kind: .image, previewText: "", sourceBundleID: nil, sourceAppName: nil,
            createdAt: Date(), lastUsedAt: Date(), useCount: 0, byteSize: 0)
        let png = try fakePNG(width: 4, height: 3)
        let image = ClipDetail(
            summary: summary, previewText: "",
            items: [PasteboardItem(representations: [PasteboardRepresentation(type: "public.png", data: png)])])
        #expect(ClipPreviewContent.image(image) != nil)
        let files = ClipDetail(summary: summary, previewText: "/tmp/a.txt\n/tmp/b.txt", items: [])
        #expect(ClipPreviewContent.paths(files) == ["/tmp/a.txt", "/tmp/b.txt"])
    }

    @Test func presentationTitles() {
        func summary(_ kind: ClipKind, _ text: String, app: String? = nil) -> ClipSummary {
            ClipSummary(
                id: 3, kind: kind, previewText: text, sourceBundleID: nil, sourceAppName: app,
                createdAt: Date(), lastUsedAt: Date(timeIntervalSince1970: 0), useCount: 0, byteSize: 0)
        }
        #expect(ClipPresentation.title(summary(.text, "\n  first line\nsecond")) == "first line")
        #expect(ClipPresentation.title(summary(.file, "/tmp/x/a.pdf\n/tmp/b.txt")) == "a.pdf, b.txt")
        #expect(ClipPresentation.icon(summary(.url, "x")) == .symbol("link"))
        #expect(ClipPresentation.entryID(ClipPresentation.itemKey(42)) == 42)
        #expect(ClipPresentation.entryID(ItemKey(pluginID: "apps", key: "42")) == nil)
        let subtitle = ClipPresentation.subtitle(
            summary(.text, "x", app: "Notes"), now: Date(timeIntervalSince1970: 60))
        #expect(subtitle.hasPrefix("Notes · "))
    }

    #if DEBUG
    @Test func qaSeedFillsOnlyAnEmptyHistory() async throws {
        let harness = try PluginHarness(settings: ["plugins.clipboard.qaSeed": .string("demo")])
        try await harness.plugin.activate()
        let store = try #require(harness.plugin.store)
        let seeded = try store.count()
        #expect(seeded == ClipboardQASeed.drafts(now: Date()).count)
        await harness.plugin.deactivate()
        try await harness.plugin.activate()
        #expect(try harness.plugin.store?.count() == seeded)
        await harness.tearDown()
    }
    #endif
}

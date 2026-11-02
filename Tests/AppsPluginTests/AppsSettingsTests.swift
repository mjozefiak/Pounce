import Foundation
import PounceKit
import Testing

@testable import AppsPlugin

@Suite @MainActor struct AppsSettingsTests {
    func makeModel(_ directory: TemporaryDirectory, settings: MemorySettings = MemorySettings()) async
        -> AppsSettingsModel
    {
        let store = ActivityStore(directory: directory.url, now: VirtualTime().now, clock: NeverClock())
        await store.load()
        return AppsSettingsModel(settings: PluginSettings(pluginID: "apps", store: settings), store: store)
    }

    @Test func theToggleWritesTheSetting() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let settings = MemorySettings()
        let model = await makeModel(directory, settings: settings)
        #expect(model.suggestionsEnabled)
        var changes: [Bool] = []
        model.suggestionsChanged = { changes.append($0) }
        model.setSuggestionsEnabled(false)
        #expect(settings.value(forKey: "plugins.apps.suggestions.enabled") == .bool(false))
        #expect(!model.suggestionsEnabled)
        #expect(changes == [false])
        model.setSpotlightEnabled(false)
        #expect(settings.value(forKey: "plugins.apps.spotlight") == .bool(false))
    }

    @Test func clearingEmptiesTheStoreAndKeepsTheSeedAway() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let model = await makeModel(directory)
        await model.store.recordUse(of: "com.example.notes", at: Date(timeIntervalSince1970: 1_800_000_000))
        model.reload()
        #expect(model.hasActivity)
        await model.clearActivity()
        #expect(model.store.snapshot.apps.isEmpty)
        #expect(model.store.snapshot.seededAt == ActivityStore.seedCleared)
        #expect(!model.hasActivity)
        // The cleared state is on disk at once.
        let reopened = ActivityStore(directory: directory.url, now: VirtualTime().now, clock: NeverClock())
        await reopened.load()
        #expect(reopened.snapshot.seededAt == ActivityStore.seedCleared)
    }

    @Test func aNewerFileDisablesClearing() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: ActivityStore.fileName)
        let original = Data(#"{"version":7}"#.utf8)
        try original.write(to: file)
        let model = await makeModel(directory)
        #expect(model.isReadOnly)
        await model.clearActivity()
        #expect(try Data(contentsOf: file) == original)
    }
}

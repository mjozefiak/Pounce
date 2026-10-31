import Foundation
import SwiftUI
import Testing

@testable import PounceKit

@Suite struct ItemKeyTests {
    @Test func formatsAsPluginIDColonKey() {
        let key = ItemKey(pluginID: "apps", key: "com.apple.Terminal")
        #expect(key.rawValue == "apps:com.apple.Terminal")
    }

    @Test func parsesOnlyTheFirstSeparator() throws {
        let key = try #require(ItemKey(rawValue: "files:/Users/me/a:b.txt"))
        #expect(key.pluginID == "files")
        #expect(key.key == "/Users/me/a:b.txt")
        #expect(key.rawValue == "files:/Users/me/a:b.txt")
    }

    @Test(arguments: ["", "apps", ":key", "apps:"])
    func rejectsMalformedKeys(_ raw: String) {
        #expect(ItemKey(rawValue: raw) == nil)
    }
}

@Suite struct MatchTierTests {
    @Test func tiersSortBestFirst() {
        let shuffled: [MatchTier] = [.fuzzy, .exact, .substring, .wordStart, .prefix]
        #expect(shuffled.sorted() == [.exact, .prefix, .wordStart, .substring, .fuzzy])
    }
}

@Suite struct PluginSettingsTests {
    @Test func namespacesKeysUnderThePluginPrefix() throws {
        let suite = "pounce-kit-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = PluginSettings(pluginID: "clipboard", defaults: defaults)
        #expect(settings.key("retentionDays") == "plugins.clipboard.retentionDays")
        #expect(settings.integer("retentionDays", default: 30) == 30)

        settings.set(7, for: "retentionDays")
        settings.set(true, for: "paused")
        settings.set(["com.1password.1password"], for: "ignoredApps")
        #expect(defaults.integer(forKey: "plugins.clipboard.retentionDays") == 7)
        #expect(settings.bool("paused", default: false))
        #expect(settings.stringArray("ignoredApps") == ["com.1password.1password"])

        settings.removeValue(for: "paused")
        #expect(!settings.bool("paused", default: false))
    }
}

@MainActor
@Suite struct DefaultContributionTests {
    final class MinimalPlugin: PouncePlugin {
        static let manifest = PluginManifest(
            id: "minimal",
            displayName: "Minimal",
            symbolName: "circle",
            order: 0
        )

        init(context: PluginContext) {}
    }

    struct MinimalSource: SearchSource {
        let id: SourceID = "minimal"

        func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] { [] }
    }

    @Test func aPluginOnlyImplementsWhatItNeeds() async throws {
        let plugin = MinimalPlugin(context: TestContext.make())
        try await plugin.activate()
        await plugin.deactivate()
        try await plugin.eraseData()
        #expect(plugin.searchSources.isEmpty)
        #expect(plugin.commands.isEmpty)
        #expect(plugin.panelModes.isEmpty)
        #expect(plugin.onboardingSteps.isEmpty)
        #expect(plugin.requiredPermissions.isEmpty)
        #expect(plugin.settingsPane() == nil)
        #expect(MinimalPlugin.manifest.defaultEnabled)
    }

    @Test func sourcesHaveNoActionsByDefault() {
        let candidate = Candidate(
            itemKey: ItemKey(pluginID: "minimal", key: "x"),
            title: "X",
            icon: .symbol("circle"),
            match: MatchResult(tier: .exact, score: 1)
        )
        #expect(MinimalSource().actions(for: candidate).isEmpty)
    }
}

/// A context whose ports do nothing, for contract tests that never call them.
enum TestContext {
    struct NoKeychain: KeychainClient {
        func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
            throw .itemNotFound
        }
        func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {}
        func deleteGenericPassword(service: String, account: String) throws(KeychainError) {}
    }

    struct NoPasteboard: PasteboardClient {
        @MainActor var changeCount: Int { 0 }
        @MainActor func string() -> String? { nil }
        @MainActor func setString(_ string: String) -> Int { 0 }
    }

    struct NoEvents: EventPoster {
        @MainActor func postPaste() throws(EventPosterError) { throw .notPermitted }
    }

    struct NoWorkspace: WorkspaceClient {
        @MainActor var frontmostApplicationPID: pid_t? { nil }
        @MainActor func open(_ url: URL) async throws {}
        @MainActor func revealInFinder(_ urls: [URL]) {}
    }

    struct NoUsage: UsageRecorder {
        func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {}
        func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] { [:] }
    }

    struct NoPermissions: PermissionsReader {
        @MainActor func status(of permission: Permission) -> PermissionStatus { .notDetermined }
    }

    static func make() -> PluginContext {
        PluginContext(
            storageDirectory: FileManager.default.temporaryDirectory.appending(path: "pounce-kit-tests"),
            settings: PluginSettings(pluginID: "minimal", defaults: .standard),
            usage: NoUsage(),
            logger: .init(subsystem: "app.pounce.tests", category: "kit"),
            keychain: NoKeychain(),
            pasteboard: NoPasteboard(),
            events: NoEvents(),
            workspace: NoWorkspace(),
            permissions: NoPermissions(),
            clock: ContinuousClock()
        )
    }
}

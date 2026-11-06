import AppKit
import Foundation
import LintelKit
import LintelUI
import SwiftUI
import Testing

@testable import ClipboardPlugin

/// Spec `2026-11-04-lintel-main-window`, step 4.4: the Clipboard pane on the `SettingsPane` template (prototypes
/// `set-clipboard` and `set-error`), its banner and the template pane. Every plugin uses a named
/// pasteboard, an in-memory keychain and a temporary folder.
@Suite @MainActor struct ClipboardPaneTests {
    private static func typeNames(in value: Any, depth: Int = 0) -> Set<String> {
        guard depth < 60 else { return [] }
        let type = String(describing: Swift.type(of: value))
        var names: Set<String> = [type.components(separatedBy: "<").first ?? type]
        for child in Mirror(reflecting: value).children {
            names.formUnion(typeNames(in: child.value, depth: depth + 1))
        }
        return names
    }

    private static func first(_ name: String, in value: Any, depth: Int = 0) -> Any? {
        guard depth < 60 else { return nil }
        let type = String(describing: Swift.type(of: value))
        if type.components(separatedBy: "<").first == name { return value }
        for child in Mirror(reflecting: value).children {
            if let found = first(name, in: child.value, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func status(
        _ availability: HistoryAvailability = .ready, access: PasteboardAccess = .alwaysAllow, paused: Bool = false,
        reset: Bool = false, count: Int = 212
    ) -> SettingsStatus? {
        ClipboardPlugin.settingsStatus(
            availability: availability, access: access, isPaused: paused, historyWasReset: reset, entryCount: count,
            retry: {}, resume: {}, dismissReset: {})
    }

    /// One plural form of a catalog key.
    private static func plural(_ key: String, _ language: String, _ form: String) throws -> String {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entry = try #require((root["strings"] as? [String: Any])?[key] as? [String: Any], "\(key)")
        let localization = try #require((entry["localizations"] as? [String: Any])?[language] as? [String: Any])
        let plural = try #require((localization["variations"] as? [String: Any])?["plural"] as? [String: Any])
        let unit = try #require((plural[form] as? [String: Any])?["stringUnit"] as? [String: Any])
        return try #require(unit["value"] as? String)
    }

    private static func pluginActionID(_ action: SettingsStatusAction?) -> String? {
        guard case .plugin(let id, _) = action?.destination else { return nil }
        return id
    }

    private func pane(_ harness: PluginHarness) -> ClipboardSettingsPane {
        ClipboardSettingsPane(
            state: harness.plugin.state, settings: harness.plugin.settings, actions: harness.plugin.statusActions,
            recorder: AnyView(EmptyView()), clearHistory: { true })
    }

    @Test func theMainWindowPaneIsBasicsAdvancedData() throws {
        let harness = try PluginHarness()
        let content = ClipboardPaneContent(
            state: harness.plugin.state, settings: harness.plugin.settings, recorder: AnyView(EmptyView()),
            clearHistory: { true })
        let template = try #require(Self.first("SettingsPane", in: content.body))
        let sections = Mirror(reflecting: template).children.compactMap { child -> (String, Bool)? in
            guard let label = child.label, ["basics", "advanced", "data"].contains(label) else { return nil }
            let mirror = Mirror(reflecting: child.value)
            return (label, mirror.displayStyle != .optional || !mirror.children.isEmpty)
        }
        #expect(sections.map(\.0) == ["basics", "advanced", "data"])
        #expect(sections.map(\.1) == [true, true, true])
        // The history banners are the host's.
        #expect(!Self.typeNames(in: content.body).contains("ClipboardBannerRow"))
    }

    @Test func thePluginsPaneIsTheTemplatePane() throws {
        let harness = try PluginHarness()
        #expect(Self.typeNames(in: pane(harness).body).contains("ClipboardPaneContent"))
    }

    @Test func thePaneRendersInEveryState() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        for availability in [HistoryAvailability.ready, .keychainLocked, .keychainUnavailable] {
            harness.plugin.state.availability = availability
            let renderer = ImageRenderer(content: pane(harness).frame(width: 680, height: 900))
            #expect(renderer.nsImage != nil)
        }
        await harness.tearDown()
    }

    // The banner.

    @Test func readyCountsTheEntries() throws {
        let status = try #require(Self.status())
        #expect(status.level == .ok)
        #expect(status.title.key == "Ready")
        #expect(String(localized: try #require(status.detail)) == "Recording. 212 entries.")
        #expect(status.fix.isEmpty)
        #expect(status.acknowledgedPermissions.isEmpty)
    }

    @Test func anUnreadableKeyIsAnErrorWithTryAgain() throws {
        for availability in [HistoryAvailability.keychainLocked, .keychainUnavailable] {
            let status = try #require(Self.status(availability))
            #expect(status.level == .error)
            #expect(status.title.key == "History is paused")
            #expect(status.fix.map { String(localized: $0.title) } == ["Try Again"])
            #expect(Self.pluginActionID(status.fix.first) == ClipboardPlugin.retryActionID)
        }
        #expect(Self.status(.keychainUnavailable)?.detail?.key == "Lintel can’t read the key. Nothing was deleted.")
        #expect(Self.status(.keychainLocked)?.detail?.key == "The keychain is locked. Nothing was deleted.")
    }

    @Test func pasteboardAccessThatRecordsNothingAsksForPrivacySettings() throws {
        for access in [PasteboardAccess.alwaysDeny, .ask] {
            let status = try #require(Self.status(access: access))
            #expect(status.level == .attention)
            #expect(status.title.key == "Nothing is recorded")
            guard case .systemSettings(.pasteboard) = status.fix.first?.destination else {
                Issue.record("Open Privacy Settings does not open the pasteboard settings")
                return
            }
        }
    }

    @Test func pausedAndResetOfferTheirOwnActions() throws {
        let paused = try #require(Self.status(paused: true, count: 1))
        #expect(paused.level == .neutral)
        #expect(String(localized: paused.title) == "Recording is paused")
        // `swift test` has no compiled catalog, so the plural rule is checked in the catalog (the app applies it).
        let detail = try #require(paused.detail)
        #expect(detail.key == "%lld entries. Nothing new is added.")
        #expect(
            try Self.plural(detail.key, "en", "one").replacing("%lld", with: "1") == "1 entry. Nothing new is added.")
        #expect(
            try Self.plural(detail.key, "pl", "one").replacing("%lld", with: "1")
                == "1 wpis. Nic nowego nie jest dodawane.")
        #expect(Self.pluginActionID(paused.fix.first) == ClipboardPlugin.resumeActionID)
        let reset = try #require(Self.status(paused: true, reset: true))
        #expect(reset.level == .attention)
        #expect(reset.title.key == "A new history was started")
        #expect(Self.pluginActionID(reset.fix.first) == ClipboardPlugin.dismissResetActionID)
        // The key comes first: an error outranks everything else.
        #expect(Self.status(.keychainLocked, access: .ask, paused: true, reset: true)?.level == .error)
        #expect(Self.status(.inactive) == nil)
    }

    @Test func tryAgainOpensTheHistoryAndDeletesNothing() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        await harness.plugin.deactivate()
        harness.keychain.state.withLock { $0.readError = .accessDenied }
        try await harness.plugin.activate()
        let status = try #require(harness.plugin.settingsStatus)
        #expect(status.level == .error)
        #expect(harness.keychain.storedKeyCount == 1)
        let database = harness.directory.url.appending(path: "Plugins/clipboard/clipboard.sqlite")
        #expect(FileManager.default.fileExists(atPath: database.path))
        guard case .plugin(_, let perform) = status.fix.first?.destination else {
            Issue.record("Try Again is missing")
            return
        }
        // Still denied: Try Again changes nothing and deletes nothing.
        await perform()
        #expect(harness.plugin.state.availability == .keychainUnavailable)
        #expect(harness.keychain.storedKeyCount == 1)
        #expect(FileManager.default.fileExists(atPath: database.path))
        // Allowed again: Try Again opens the same history.
        harness.keychain.state.withLock { $0.readError = nil }
        await perform()
        #expect(harness.plugin.state.availability == .ready)
        #expect(harness.plugin.settingsStatus?.level == .ok)
        await harness.tearDown()
    }

    // Step 4.3 review fix: the banner getter only reads; access is re-checked on app activation.

    @Test func readingTheBannerChangesNothing() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        harness.pasteboard.access = .alwaysDeny
        harness.permissions.accessibility = .denied
        let changes = harness.changes.value
        #expect(harness.plugin.settingsStatus?.level == .ok)
        #expect(harness.plugin.settingsStatus?.level == .ok)
        #expect(harness.plugin.state.access == .alwaysAllow)
        #expect(harness.plugin.state.pasteAllowed)
        #expect(harness.plugin.shared.pasteAllowed)
        #expect(harness.changes.value == changes)
        await harness.tearDown()
    }

    @Test func changedAccessShowsAfterComingBack() async throws {
        let harness = try PluginHarness()
        let center = NotificationCenter()
        harness.plugin.appActivationCenter = center
        try await harness.plugin.activate()
        harness.pasteboard.access = .alwaysDeny
        let changes = harness.changes.value
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(harness.plugin.state.access == .alwaysDeny)
        #expect(harness.changes.value > changes)
        #expect(harness.plugin.settingsStatus?.title.key == "Nothing is recorded")
        // Nothing changed: no signal.
        let after = harness.changes.value
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(harness.changes.value == after)
        // The pane's appearance re-checks too.
        harness.pasteboard.access = .alwaysAllow
        harness.plugin.statusActions.recheck()
        #expect(harness.plugin.settingsStatus?.level == .ok)
        await harness.tearDown()
    }

    @Test func pausingSignalsTheBanner() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let before = harness.changes.value
        harness.plugin.settings.setPaused(true)
        #expect(harness.changes.value > before)
        #expect(harness.plugin.settingsStatus?.level == .neutral)
        await harness.tearDown()
    }

    @Test func theNewStringsAreTranslated() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        for key in [
            "Recording. %lld entries.", "%lld entries. Nothing new is added.", "%lld entries (clipboard maximum)",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "\(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let polish = try #require(localizations["pl"] as? [String: Any])
            let plural = try #require((polish["variations"] as? [String: Any])?["plural"] as? [String: Any])
            #expect(Set(plural.keys) == ["one", "few", "many", "other"], "\(key)")
        }
        for key in [
            "Keep clipboard history", "At most (clipboard)", "Encrypted on this Mac.", "History is paused",
            "The keychain is locked. Nothing was deleted.", "Lintel can’t read the key. Nothing was deleted.",
            "Nothing is recorded", "Lintel isn’t allowed to read the clipboard.",
            "macOS asks before every read. Allow Lintel in Privacy & Security.", "A new history was started",
            "The key was missing. The old history stays encrypted and is deleted after 30 days.",
            "Recording is paused (banner)", "Keep for", "Shortcut", "History", "Clear History…",
        ] {
            let item = try #require(strings[key] as? [String: Any], "\(key)")
            let both = try #require(item["localizations"] as? [String: Any])
            #expect(both["en"] != nil && both["pl"] != nil, "\(key)")
        }
    }
}

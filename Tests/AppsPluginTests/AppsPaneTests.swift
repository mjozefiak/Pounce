import AppKit
import Foundation
import LintelKit
import LintelUI
import SwiftUI
import Testing

@testable import AppsPlugin

/// Spec `2026-11-04-lintel-main-window`, step 4.2: the Apps pane on the `SettingsPane` template (prototype
/// `set-apps`) and its banner.
@Suite @MainActor struct AppsPaneTests {
    private func makeModel(_ directory: TemporaryDirectory) async -> AppsSettingsModel {
        let store = ActivityStore(directory: directory.url, now: VirtualTime().now, clock: NeverClock())
        await store.load()
        return AppsSettingsModel(settings: PluginSettings(pluginID: "apps", store: MemorySettings()), store: store)
    }

    /// The view types a `body` holds, found by reflection (the branch an `if` took is stored, the other is not).
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

    @Test func theMainWindowPaneIsBasicsAdvancedData() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let pane = AppsPaneContent(model: await makeModel(directory))
        let template = try #require(Self.first("SettingsPane", in: pane.body))
        let sections = Mirror(reflecting: template).children.compactMap { child -> (String, Bool)? in
            guard let label = child.label, ["basics", "advanced", "data"].contains(label) else { return nil }
            let mirror = Mirror(reflecting: child.value)
            return (label, mirror.displayStyle != .optional || !mirror.children.isEmpty)
        }
        #expect(sections.map(\.0) == ["basics", "advanced", "data"])
        #expect(sections.map(\.1) == [true, true, true])
    }

    @Test func thePluginsPaneIsTheTemplatePane() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let types = Self.typeNames(in: AppsSettingsPane(model: await makeModel(directory)).body)
        #expect(types.contains("AppsPaneContent"))
    }

    @Test func thePaneRenders() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let model = await makeModel(directory)
        model.roots = { [URL(filePath: "/tmp/apps-fixture", directoryHint: .isDirectory)] }
        let renderer = ImageRenderer(content: AppsSettingsPane(model: model).frame(width: 680, height: 700))
        #expect(renderer.nsImage != nil)
        let sheet = ImageRenderer(content: HiddenSuggestionsSheet(model: model) {})
        #expect(sheet.nsImage != nil)
    }

    // The banner.

    @Test func theBannerCountsTheIndexedApps() throws {
        let status = try #require(AppsPlugin.status(appCount: 312, activityIsReadOnly: false))
        #expect(status.level == .ok)
        #expect(status.title.key == "Ready")
        #expect(status.detail?.key == "%lld apps indexed.")
        #expect(String(localized: try #require(status.detail)) == "312 apps indexed.")
        #expect(status.fix.isEmpty)
    }

    @Test func beforeTheFirstListTheShellSaysReady() {
        #expect(AppsPlugin.status(appCount: 0, activityIsReadOnly: false) == nil)
    }

    @Test func aNewerActivityFileNeedsAttention() throws {
        let status = try #require(AppsPlugin.status(appCount: 312, activityIsReadOnly: true))
        #expect(status.level == .attention)
        #expect(status.title.key == "Suggestions are off")
    }

    @Test func theBannerStringsAreTranslated() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings["%lld apps indexed."] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let polish = try #require(localizations["pl"] as? [String: Any])
        let plural = try #require((polish["variations"] as? [String: Any])?["plural"] as? [String: Any])
        #expect(Set(plural.keys) == ["one", "few", "many", "other"])
        for resource in [
            AppsSettingsPane.resetConfirmation.prompt, AppsSettingsPane.resetConfirmation.detail,
            AppsSettingsPane.resetConfirmation.confirmTitle,
        ] {
            let item = try #require(strings[resource.key] as? [String: Any], "\(resource.key)")
            let both = try #require(item["localizations"] as? [String: Any])
            #expect(both["en"] != nil && both["pl"] != nil, "\(resource.key)")
        }
    }
}

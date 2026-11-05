import AppKit
import Foundation
import LintelKit
import LintelUI
import SwiftUI
import Testing

@testable import LintelApp

/// Like the coming Notes plugin: it cannot be turned off.
final class AlwaysOnNotesPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "always-on-notes", displayName: "Notes", symbolName: "doc", order: 0, canBeDisabled: false)

    init(context: PluginContext) {}
}

/// Needs the microphone, which nothing else in these tests does.
final class ListeningPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "listening", displayName: "Listening", symbolName: "mic", order: 3)

    init(context: PluginContext) {}

    var requiredPermissions: Set<Permission> { [.microphone] }
}

/// A plain search feature; these tests do not use the shared `LifecycleLog` plugins, which other suites watch.
final class PlainFeaturePlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "plain", displayName: "Plain", symbolName: "p.circle", order: 1)

    init(context: PluginContext) {}

    var searchSources: [any SearchSource] { [InstantSource(id: "plain.source")] }
}

/// A second search feature, off by default.
final class OtherFeaturePlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "other", displayName: "Other", symbolName: "o.circle", order: 2, defaultEnabled: false)

    init(context: PluginContext) {}

    var searchSources: [any SearchSource] { [InstantSource(id: "other.source")] }
}

/// The view types and stored values a `body` holds, found by reflection (the branch an `if` took is stored, the
/// other is not).
enum PaneTree {
    static func typeNames(in value: Any) -> Set<String> {
        var names: Set<String> = []
        visit(value, depth: 0) { names.insert(baseName(of: $0)) }
        return names
    }

    /// The first value whose type is `name<...>`.
    static func first(_ name: String, in value: Any) -> Any? {
        var found: Any?
        visit(value, depth: 0) { if found == nil, baseName(of: $0) == name { found = $0 } }
        return found
    }

    private static func baseName(of value: Any) -> String {
        let type = String(describing: Swift.type(of: value))
        return type.components(separatedBy: "<").first ?? type
    }

    private static func visit(_ value: Any, depth: Int, _ body: (Any) -> Void) {
        guard depth < 60 else { return }
        body(value)
        for child in Mirror(reflecting: value).children {
            visit(child.value, depth: depth + 1, body)
        }
    }
}

/// Spec `2026-11-04-lintel-main-window`, step 4.1: General and Features on the `SettingsPane` template, the shell
/// panes' banners, the "Always on" chip and the old window's unchanged panes.
@MainActor
@Suite(.serialized) struct ShellPanesTests {
    let env: TestEnvironment

    init() throws {
        env = try TestEnvironment()
    }

    private func hotkeys() -> HotkeyService {
        HotkeyService(registrar: InMemoryHotkeyRegistrar(), settings: env.settings, readOccupied: { [] })
    }

    /// The template's sections of the `SettingsPane` inside `body`, in its stored order, and which are present.
    private func templateSections(_ body: Any) throws -> [(label: String, present: Bool)] {
        let pane = try #require(PaneTree.first("SettingsPane", in: body))
        return Mirror(reflecting: pane).children.compactMap { child in
            guard let label = child.label, ["basics", "advanced", "data"].contains(label) else { return nil }
            let mirror = Mirror(reflecting: child.value)
            let present = mirror.displayStyle != .optional || !mirror.children.isEmpty
            return (label, present)
        }
    }

    // Structure.

    @Test func generalIsBasicsOnly() throws {
        defer { env.tearDown() }
        let pane = GeneralPaneContent(
            hotkeys: hotkeys(), settings: AppSettings(store: env.settings), launchAtLogin: InMemoryLaunchAtLogin())
        let sections = try templateSections(pane.body)
        #expect(sections.map(\.label) == ["basics", "advanced", "data"])
        #expect(sections.map(\.present) == [true, false, false])
    }

    @Test func featuresHasBasicsAndAdvancedButNoData() async throws {
        defer { env.tearDown() }
        let host = env.makeHost([PlainFeaturePlugin.self, OtherFeaturePlugin.self])
        await host.start()
        let pane = FeaturesPaneContent(
            controls: FeatureControls(host: host) {},
            order: SectionOrderControls(host: host, settings: AppSettings(store: env.settings)))
        let sections = try templateSections(pane.body)
        #expect(sections.map(\.label) == ["basics", "advanced", "data"])
        #expect(sections.map(\.present) == [true, true, false])
    }

    // The old window (release users) keeps today's panes.

    @Test func theOldWindowKeepsTodaysGeneralPane() throws {
        defer { env.tearDown() }
        let settings = AppSettings(store: env.settings)
        let pane = GeneralPane(hotkeys: hotkeys(), settings: settings, launchAtLogin: InMemoryLaunchAtLogin())
        let types = PaneTree.typeNames(in: pane.body)
        #expect(types.contains("LegacyGeneralPane"))
        #expect(!types.contains("GeneralPaneContent"))
        let legacy = PaneTree.typeNames(
            in: LegacyGeneralPane(hotkeys: hotkeys(), settings: settings, launchAtLogin: InMemoryLaunchAtLogin())
                .body)
        #expect(legacy.contains("Form"))
        #expect(legacy.contains("MainShortcutRecorder"))
        #expect(!legacy.contains("SettingsPane"))
    }

    @Test func theOldWindowKeepsTodaysFeaturesPane() async throws {
        defer { env.tearDown() }
        let host = env.makeHost([PlainFeaturePlugin.self])
        await host.start()
        let pane = FeaturesPane(host: host, settings: AppSettings(store: env.settings)) {}
        let types = PaneTree.typeNames(in: pane.body)
        #expect(types.contains("LegacyFeaturesPane"))
        #expect(!types.contains("FeaturesPaneContent"))
        let legacy = PaneTree.typeNames(in: LegacyFeaturesPane(controls: pane.controls, order: pane.order).body)
        #expect(legacy.contains("Form"))
        #expect(!legacy.contains("SettingsPane"))
    }

    @Test func bothHostsRenderBothPanes() async throws {
        defer { env.tearDown() }
        let host = env.makeHost([AlwaysOnNotesPlugin.self, PlainFeaturePlugin.self, OtherFeaturePlugin.self])
        await host.start()
        let settings = AppSettings(store: env.settings)
        for style in [SettingsHostStyle.legacyWindow, .mainWindow] {
            let general = GeneralPane(hotkeys: hotkeys(), settings: settings, launchAtLogin: InMemoryLaunchAtLogin())
            let features = FeaturesPane(host: host, settings: settings) {}
            for view in [AnyView(general), AnyView(features)] {
                let renderer = ImageRenderer(
                    content: view.environment(\.settingsHostStyle, style).frame(width: 600, height: 700))
                #expect(renderer.nsImage != nil)
            }
        }
    }

    // "Always on".

    @Test func aPluginThatCannotBeTurnedOffGetsTheChip() async {
        defer { env.tearDown() }
        #expect(FeatureAccessory(AlwaysOnNotesPlugin.manifest) == .alwaysOn)
        #expect(FeatureAccessory(PlainFeaturePlugin.manifest) == .toggle)
        let host = env.makeHost([AlwaysOnNotesPlugin.self, PlainFeaturePlugin.self])
        await host.start()
        // A stored `false` does not turn it off, so the Features banner counts it as on.
        await host.setEnabled(false, for: AlwaysOnNotesPlugin.manifest.id)
        #expect(host.isEnabled(AlwaysOnNotesPlugin.manifest.id))
        #expect(ShellPaneBanners.features(host: host).detail == "All features are on.")
    }

    @Test func aFeatureRowSaysOnlyWhatTheSwitchDoesNot() {
        #expect(FeatureSwitchRow.detail(for: .active) == nil)
        #expect(FeatureSwitchRow.detail(for: .disabled) == nil)
        #expect(FeatureSwitchRow.detail(for: .activating) == "Starting…")
        #expect(FeatureSwitchRow.detail(for: .failed(TestError.activationFailed))?.hasPrefix("Unavailable: ") == true)
    }

    // Banners of the shell panes.

    @Test func generalSaysReadyWithTheShortcut() {
        let banner = ShellPaneBanners.general(shortcut: HotkeyShortcut.commandSpace.displayString)
        #expect(banner.level == .ok)
        #expect(banner.title == "Ready")
        #expect(banner.detail == "Press ⌘Space to open Lintel.")
        #expect(banner.actions.isEmpty)
        let none = ShellPaneBanners.general(shortcut: nil)
        #expect(none.level == .attention)
        #expect(none.title == "No shortcut is set")
    }

    @Test func featuresSaysAllSet() {
        let on = ShellPaneBanners.Feature(isEnabled: true, isFailed: false)
        let off = ShellPaneBanners.Feature(isEnabled: false, isFailed: false)
        let all = ShellPaneBanners.features([on, on])
        #expect(all.level == .ok)
        #expect(all.title == "All set")
        #expect(all.detail == "All features are on.")
        #expect(ShellPaneBanners.features([on, off]).detail == "Some features are off.")
        let failed = ShellPaneBanners.features([on, ShellPaneBanners.Feature(isEnabled: true, isFailed: true)])
        #expect(failed.level == .attention)
        #expect(failed.title == "A feature couldn't start")
    }

    @Test func permissionsCountsWhatIsLeftToAllow() async {
        defer { env.tearDown() }
        let host = env.makeHost([ListeningPlugin.self])
        await host.start()
        let reader = FakePermissionsReader()
        reader.answers[.microphone] = .denied
        let banner = ShellPaneBanners.permissions(host: host, reader: reader)
        #expect(banner.level == .attention)
        #expect(banner.title == String(localized: "\(1) things to do"))
        #expect(banner.detail == "Features that are on can't start until these are allowed.")
        reader.answers[.microphone] = .granted
        let ready = ShellPaneBanners.permissions(host: host, reader: reader)
        #expect(ready.level == .ok)
        #expect(ready.title == "Ready")
        // A permission no enabled feature needs is not counted.
        await host.setEnabled(false, for: ListeningPlugin.manifest.id)
        reader.answers[.microphone] = .denied
        #expect(ShellPaneBanners.permissions(host: host, reader: reader).level == .ok)
    }

    @Test func unreadableAndAcknowledgedPermissionsAreNotCounted() {
        let requirements = [
            PermissionRequirement(permission: .microphone, pluginNames: ["A"]),
            PermissionRequirement(permission: .fullDiskAccess, pluginNames: ["Files"]),
        ]
        let banner = ShellPaneBanners.permissions(
            requirements: requirements, status: { _ in .notDetermined }, acknowledged: [.fullDiskAccess])
        #expect(banner.title == String(localized: "\(1) things to do"))
        let unreadable = Permission.allCases.filter { !$0.isReadable }.map {
            PermissionRequirement(permission: $0, pluginNames: ["B"])
        }
        #expect(ShellPaneBanners.permissions(requirements: unreadable, status: { _ in .denied }).level == .ok)
    }

    @Test func thingsToDoHasEveryPolishPluralForm() throws {
        let data = try Data(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/Localizable.xcstrings"))
        let catalog = try JSONDecoder().decode(StringCatalogTests.Catalog.self, from: data)
        let entry = try #require(catalog.strings["%lld things to do"])
        let plural = try #require(entry.localizations?["pl"]?.variations?.plural)
        #expect(Set(plural.keys) == ["one", "few", "many", "other"])
        #expect(plural["one"]?.stringUnit?.value == "%lld rzecz do zrobienia")
        let english = try #require(entry.localizations?["en"]?.variations?.plural)
        #expect(english["one"]?.stringUnit?.value == "%lld thing to do")
    }

    @Test func theHostDrawsTheShellPanesBannersAndTitles() async {
        defer { env.tearDown() }
        let host = env.makeHost([PlainFeaturePlugin.self])
        await host.start()
        let model = SettingsHostModel(
            host: host, reader: FakePermissionsReader(),
            shellBanners: [
                "general": { ShellPaneBanners.general(shortcut: "⌘Space") },
                "features": { ShellPaneBanners.features(host: host) },
            ])
        model.show("general")
        #expect(model.shownBanner?.detail == "Press ⌘Space to open Lintel.")
        #expect(model.title(of: "general") == "General")
        model.show("features")
        #expect(model.shownBanner?.title == "All set")
        #expect(model.title(of: "features") == "Features")
        model.show("advanced")
        #expect(model.shownBanner == nil)
        #expect(model.title(of: "advanced") == "Advanced")
    }
}

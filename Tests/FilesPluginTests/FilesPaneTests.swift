import AppKit
import Foundation
import LintelKit
import LintelUI
import SwiftUI
import Testing

@testable import FilesPlugin

/// Spec `2026-11-04-lintel-main-window`, step 4.3: the Files pane on the `SettingsPane` template (prototype
/// `set-files`), its banner, and the old window's unchanged pane. Every plugin works on a fake home in a
/// temporary folder; no protected location is touched.
@Suite @MainActor struct FilesPaneTests {
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

    private static func status(
        _ phase: IndexStatus.Phase, count: Int = 0, setupCompleted: Bool = true,
        access: PermissionStatus = .denied
    ) -> SettingsStatus {
        FilesPlugin.settingsStatus(
            status: IndexStatus(phase: phase, count: count), setupCompleted: setupCompleted,
            fullDiskAccess: access, startIndexing: {})
    }

    @Test func theMainWindowPaneIsBasicsAdvancedData() throws {
        let harness = try PluginHarness()
        let pane = FilesPaneContent(model: harness.plugin.viewModel)
        let template = try #require(Self.first("SettingsPane", in: pane.body))
        let sections = Mirror(reflecting: template).children.compactMap { child -> (String, Bool)? in
            guard let label = child.label, ["basics", "advanced", "data"].contains(label) else { return nil }
            let mirror = Mirror(reflecting: child.value)
            return (label, mirror.displayStyle != .optional || !mirror.children.isEmpty)
        }
        #expect(sections.map(\.0) == ["basics", "advanced", "data"])
        #expect(sections.map(\.1) == [true, true, true])
    }

    @Test func theOldWindowKeepsTodaysPane() throws {
        let harness = try PluginHarness()
        // Outside a host the environment is the default, `.legacyWindow`: what release users see.
        let types = Self.typeNames(in: FilesSettingsPane(model: harness.plugin.viewModel).body)
        #expect(types.contains("LegacyFilesSettingsPane"))
        #expect(!types.contains("FilesPaneContent"))
        let legacy = Self.typeNames(in: LegacyFilesSettingsPane(model: harness.plugin.viewModel).body)
        #expect(legacy.contains("Form"))
        #expect(!legacy.contains("SettingsPane"))
    }

    @Test func bothHostsRenderThePane() throws {
        let harness = try PluginHarness(settings: ["plugins.files.exclusions": .stringArray(["*.log"])])
        for access in [PermissionStatus.denied, .granted] {
            harness.permissions.fullDiskAccess = access
            harness.plugin.refreshAccess()
            for style in [SettingsHostStyle.legacyWindow, .mainWindow] {
                let renderer = ImageRenderer(
                    content: FilesSettingsPane(model: harness.plugin.viewModel)
                        .environment(\.settingsHostStyle, style)
                        .frame(width: 600, height: 900))
                #expect(renderer.nsImage != nil)
            }
        }
    }

    // The banner.

    @Test func beforeTheFirstScanIndexingHasNotStarted() throws {
        let status = Self.status(.waiting, setupCompleted: false)
        #expect(status.level == .attention)
        #expect(status.title.key == "Indexing hasn’t started")
        #expect(status.detail?.key == "Full Disk Access adds Documents and Desktop.")
        #expect(status.fix.map { String(localized: $0.title) } == ["Start Indexing", "Allow Full Disk Access"])
        guard case .plugin(let id, _) = status.fix.first?.destination else {
            Issue.record("Start Indexing is not a plugin action")
            return
        }
        #expect(id == FilesPlugin.startIndexingActionID)
        guard case .systemSettings(.fullDiskAccess) = status.fix.last?.destination else {
            Issue.record("Allow Full Disk Access does not open the Full Disk Access settings")
            return
        }
        #expect(status.acknowledgedPermissions == [.fullDiskAccess])
    }

    @Test func withAccessOnlyStartIndexingIsOffered() {
        let status = Self.status(.waiting, setupCompleted: false, access: .granted)
        #expect(status.fix.count == 1)
        #expect(status.detail?.key == "Start indexing to find files by name.")
        #expect(status.acknowledgedPermissions.isEmpty)
    }

    @Test func progressWhileTheIndexLoadsOrScans() throws {
        #expect(Self.status(.loading).level == .neutral)
        #expect(Self.status(.loading).title.key == "Loading the file index…")
        let scanning = Self.status(.scanning, count: 120)
        #expect(scanning.level == .neutral)
        #expect(scanning.title.key == "Indexing…")
        let progress = String(localized: try #require(scanning.detail))
        #expect(progress == "120 items so far.", "\(progress)")
    }

    @Test func readyCountsTheIndexedItemsAndAcknowledgesMissingAccess() throws {
        let without = Self.status(.ready, count: 480)
        #expect(without.level == .ok)
        #expect(without.title.key == "Ready")
        let withoutDetail = String(localized: try #require(without.detail))
        #expect(withoutDetail == "480 items indexed. Full Disk Access adds Documents and Desktop.", "\(withoutDetail)")
        #expect(without.acknowledgedPermissions == [.fullDiskAccess])
        #expect(without.fix.count == 1)
        let with = Self.status(.ready, count: 1, access: .granted)
        let withDetail = String(localized: try #require(with.detail))
        #expect(withDetail == "1 items indexed.", "\(withDetail)")
        #expect(with.fix.isEmpty)
        #expect(with.acknowledgedPermissions.isEmpty)
    }

    @Test func startIndexingStartsTheFirstScan() async throws {
        let harness = try PluginHarness()
        try harness.directory.make(["home/Projects/notes.txt"])
        try await harness.plugin.activate()
        let status = try #require(harness.plugin.settingsStatus)
        guard case .plugin(_, let perform) = status.fix.first?.destination else {
            Issue.record("Start Indexing is missing")
            return
        }
        await perform()
        #expect(harness.plugin.settings.setupCompleted)
        #expect(await eventually { harness.plugin.state.status.phase == .ready })
        #expect(harness.plugin.settingsStatus?.level == .ok)
        await harness.plugin.deactivate()
    }

    @Test func theBannerStringsAreTranslated() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        for key in [
            "%lld items indexed.", "%lld items so far.",
            "%lld items indexed. Full Disk Access adds Documents and Desktop.",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "\(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let polish = try #require(localizations["pl"] as? [String: Any])
            let plural = try #require((polish["variations"] as? [String: Any])?["plural"] as? [String: Any])
            #expect(Set(plural.keys) == ["one", "few", "many", "other"], "\(key)")
        }
        let confirmation = FilesSettingsPane.rebuildConfirmation
        for key in [
            "Indexing hasn’t started", "Full Disk Access adds Documents and Desktop.", "Start Indexing (banner)",
            "Allow Full Disk Access", "Indexing…", "Start indexing to find files by name.", "Folders to index",
            "Home folder and Applications", "Home folder", "Include iCloud Drive", "Not built yet", "Rebuild…",
            "Without Full Disk Access, macOS asks once for this folder.",
            confirmation.prompt.key, confirmation.detail.key, confirmation.confirmTitle.key,
        ] {
            let item = try #require(strings[key] as? [String: Any], "\(key)")
            let both = try #require(item["localizations"] as? [String: Any])
            #expect(both["en"] != nil && both["pl"] != nil, "\(key)")
        }
    }
}

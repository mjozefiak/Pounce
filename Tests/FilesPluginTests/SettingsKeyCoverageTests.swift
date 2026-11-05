import Foundation
import LintelKit
import Testing

@testable import FilesPlugin

/// Spec `2026-11-04-lintel-main-window`, step 2.4 (risk R-A4): every key of the Files plugin's settings type is
/// either used by its settings pane (the token is a setter or control the pane sources must contain) or listed
/// in `exempt` with the reason it has no control. A new key fails `everyKeyIsReachableOrExempt` until it is
/// added to one of the two tables.
@Suite struct SettingsKeyCoverageTests {
    /// Key constant name to a token that must appear in the pane sources.
    static let paneTokens: [String: String] = [
        "roots": "settings.addRoot",
        "exclusions": "settings.addExclusion",
        "protectedFolders": "settings.setProtected",
        "iCloudDrive": "setIncludesICloudDrive",
        "includesHidden": "settings.setIncludesHidden",
        "setupCompleted": "model.completeSetup()",
    ]

    /// Keys with no pane control, each with the reason.
    static let exempt: [String: String] = [
        "accessNoticeDismissed": "internal flag: the panel notice was dismissed, not a Settings control",
        "qaHome": "DEBUG-only QA fake home folder, not a user setting",
    ]

    /// The pane view and model sources, relative to the repository root.
    static let paneFiles = [
        "Sources/FilesPlugin/FilesViews.swift",
        "Sources/FilesPlugin/FilesSettingsPane.swift",
    ]

    /// The label (or `type:` row view) the pane (`FilesPaneContent`, step 4.3) shows for each non-exempt key's
    /// control, found in the built view. "Start Indexing" (`setupCompleted`) is the banner's action, checked by
    /// `theBannerCompletesSetup`.
    static let controls: [String: String] = [
        "roots": "Add Folder…", "exclusions": "New exclusion", "protectedFolders": "type:ProtectedFoldersRows",
        "iCloudDrive": "Include iCloud Drive", "includesHidden": "Include hidden files",
    ]

    /// Keys whose control is the banner, not the pane.
    static let bannerKeys: Set<String> = ["setupCompleted"]

    private static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// The constant names declared inside the key enum of the settings source.
    private static func declaredKeys() throws -> [String] {
        let source = try read("Sources/FilesPlugin/FilesSettings.swift")
        guard let header = source.range(of: "enum Key {") else { return [] }
        let rest = source[header.upperBound...]
        let body = rest[..<(rest.range(of: "\n    }")?.lowerBound ?? rest.endIndex)]
        return body.matches(of: #/static let (\w+) = "/#).map { String($0.1) }
    }

    @Test func everyKeyIsReachableOrExempt() throws {
        let declared = try Self.declaredKeys()
        #expect(!declared.isEmpty, "the key enum was not found in the settings source")
        for key in declared {
            let inPane = Self.paneTokens[key] != nil
            let isExempt = Self.exempt[key] != nil
            #expect(inPane != isExempt, "\(key) must be in exactly one of paneTokens and exempt")
        }
        let known = Set(Self.paneTokens.keys).union(Self.exempt.keys)
        #expect(known == Set(declared), "a table row names a key that no longer exists: \(known.subtracting(declared))")
    }

    @Test func paneSourcesReferenceEveryNonExemptKey() throws {
        let panes = try Self.paneFiles.map { try Self.read($0) }.joined(separator: "\n")
        for (key, token) in Self.paneTokens {
            #expect(panes.contains(token), "\(key): the pane sources do not contain \(token)")
        }
        for (key, reason) in Self.exempt {
            #expect(!reason.isEmpty, "\(key) needs a reason")
        }
    }

    @MainActor @Test func thePaneShowsEveryNonExemptKey() throws {
        let harness = try PluginHarness()
        let pane = PaneText(FilesPaneContent(model: harness.plugin.viewModel), module: "FilesPlugin")
        #expect(Set(Self.controls.keys) == Set(Self.paneTokens.keys).subtracting(Self.bannerKeys))
        for (key, label) in Self.controls {
            #expect(pane.shows(label), "\(key): the pane does not show \(label)")
        }
    }

    /// The banner's Start Indexing sets `setupCompleted`.
    @MainActor @Test func theBannerCompletesSetup() async throws {
        let harness = try PluginHarness()
        try await harness.plugin.activate()
        let start = harness.plugin.settingsStatus?.fix.first { action in
            if case .plugin(let id, _) = action.destination { return id == FilesPlugin.startIndexingActionID }
            return false
        }
        guard case .plugin(_, let perform) = start?.destination else {
            Issue.record("the banner has no Start Indexing")
            return
        }
        #expect(!harness.plugin.settings.setupCompleted)
        await perform()
        #expect(harness.plugin.settings.setupCompleted)
        #expect(harness.settings.value(forKey: "plugins.files.setupCompleted") == .bool(true))
        await harness.plugin.deactivate()
    }
}

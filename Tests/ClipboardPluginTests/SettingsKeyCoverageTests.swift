import Foundation
import SwiftUI
import Testing

@testable import ClipboardPlugin

/// Spec `2026-11-04-lintel-main-window`, step 2.4 (risk R-A4): every key of the Clipboard plugin's settings type is
/// either used by its settings pane (the token is a setter or control the pane sources must contain) or listed
/// in `exempt` with the reason it has no control. A new key fails `everyKeyIsReachableOrExempt` until it is
/// added to one of the two tables.
@Suite struct SettingsKeyCoverageTests {
    /// Key constant name to a token that must appear in the pane sources.
    static let paneTokens: [String: String] = [
        "paused": "settings.setPaused",
        "retentionDays": "settings.setRetentionDays",
        "maximumEntries": "settings.setMaximumEntries",
        "ignoredApps": "settings.addIgnoredApp",
    ]

    /// Keys with no pane control, each with the reason.
    static let exempt: [String: String] = [
        "historyResetNotice": "internal flag: the history was reset, cleared when the panel notice is dismissed",
        "qaSeed": "DEBUG-only QA seed, not a user setting",
    ]

    /// The pane view and model sources, relative to the repository root.
    static let paneFiles = [
        "Sources/ClipboardPlugin/ClipboardSettingsPane.swift",
        "Sources/ClipboardPlugin/LegacyClipboardSettingsPane.swift",
    ]

    /// The label each window's pane shows for each non-exempt key's control (step 4.4): the main window's
    /// `ClipboardPaneContent` and the old window's `LegacyClipboardSettingsPane`, found in the built views.
    static let windowControls: [(window: String, labels: [String: String])] = [
        (
            "main",
            [
                "paused": "Keep clipboard history", "retentionDays": "Keep for",
                "maximumEntries": "At most (clipboard)",
                "ignoredApps": "Add App…",
            ]
        ),
        (
            "old",
            [
                "paused": "Record clipboard history", "retentionDays": "Keep entries for",
                "maximumEntries": "Keep at most", "ignoredApps": "Add App…",
            ]
        ),
    ]

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
        let source = try read("Sources/ClipboardPlugin/ClipboardSettings.swift")
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

    @MainActor @Test func bothWindowsShowEveryNonExemptKey() throws {
        let harness = try PluginHarness()
        let plugin = harness.plugin
        let panes = [
            PaneText(
                ClipboardPaneContent(
                    state: plugin.state, settings: plugin.settings, recorder: AnyView(EmptyView()),
                    clearHistory: { true }),
                module: "ClipboardPlugin"),
            PaneText(
                LegacyClipboardSettingsPane(
                    state: plugin.state, settings: plugin.settings, actions: plugin.statusActions,
                    recorder: AnyView(EmptyView()), clearHistory: { true }),
                module: "ClipboardPlugin"),
        ]
        for (pane, window) in zip(panes, Self.windowControls) {
            #expect(Set(window.labels.keys) == Set(Self.paneTokens.keys), "\(window.window)")
            for (key, label) in window.labels {
                #expect(pane.shows(label), "\(key): the \(window.window) window's pane does not show \(label)")
            }
        }
    }
}

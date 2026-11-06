import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// Spec `2026-11-04-lintel-main-window`, step 2.4 (risk R-A4): every `SettingsKeys` entry has exactly one
/// owner, so moving panes into the main window cannot leave a setting without a control. A new key fails
/// `everyKeyHasExactlyOneOwner` until it is added to the table below.
@Suite struct SettingsKeyOwnershipTests {
    enum Owner {
        /// A control in a shell pane; `token` must appear in that pane's source file.
        case pane(file: String, token: String)
        /// State of the main window itself, not a pane control.
        case windowState
        /// Not a user-facing setting; the reason says why no pane shows it.
        case exempt(String)
    }

    /// The table: one row per key of `SettingsKeys`. `plugins.<id>.enabled` is the Features pane's toggle.
    static let owners: [(key: String, owner: Owner)] = [
        (SettingsKeys.pluginEnabled("example"), .pane(file: "FeaturesPane.swift", token: "setEnabled")),
        (SettingsKeys.sectionOrder, .pane(file: "FeaturesPane.swift", token: "settings.sectionOrder")),
        (SettingsKeys.showInDock, .pane(file: "GeneralPane.swift", token: "settings.showInDock")),
        (SettingsKeys.textSize, .pane(file: "GeneralPane.swift", token: "settings.textSize")),
        (SettingsKeys.hotkeyUserDefined, .pane(file: "GeneralPane.swift", token: "MainShortcutRecorder")),
        (SettingsKeys.mainWindowMode, .windowState),
        (SettingsKeys.mainWindowSection, .windowState),
        (SettingsKeys.mainWindowSettingsPane, .windowState),
        (
            SettingsKeys.commandShortcutDefaultsApplied,
            .exempt("internal flag list: default shortcuts already applied once")
        ),
        (SettingsKeys.onboardingShortcutCompleted, .exempt("internal flag: the welcome Shortcut step was finished")),
        (SettingsKeys.onboardingCompletedSteps, .exempt("internal flag list: finished plugin onboarding steps")),
        (SettingsKeys.panelLevel, .exempt("fallback switch for the launcher panel level, set with defaults only")),
    ]

    private var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    @Test func everyKeyHasExactlyOneOwner() throws {
        let source = try read("Sources/LintelApp/SettingsKeys.swift")
        let declared = source.matches(of: #/static let (\w+) = "([^"]+)"/#).map { String($0.2) }
        // `pluginEnabled(_:)` is the one function-shaped key.
        #expect(source.contains("static func pluginEnabled"))
        let tabled = Self.owners.map(\.key)
        #expect(Set(tabled).count == tabled.count, "a key has two owners")
        for key in declared {
            #expect(tabled.filter { $0 == key }.count == 1, "\(key) needs exactly one owner in the table")
        }
        #expect(tabled.count == declared.count + 1, "the table has a row that is not a SettingsKeys entry")
    }

    @Test func paneOwnersReferenceTheirKeyInThePaneSource() throws {
        for (key, owner) in Self.owners {
            guard case .pane(let file, let token) = owner else { continue }
            let text = try read("Sources/LintelApp/Settings/\(file)")
            #expect(text.contains(token), "\(key): \(file) does not contain \(token)")
        }
    }

    @Test func windowStateKeysAreWrittenByTheWindowState() throws {
        let text = try read("Sources/LintelApp/Window/MainWindowState.swift")
        for (key, owner) in Self.owners {
            guard case .windowState = owner else { continue }
            #expect(key.hasPrefix("app.mainWindow."))
        }
        for name in ["mainWindowMode", "mainWindowSection", "mainWindowSettingsPane"] {
            #expect(text.contains("SettingsKeys.\(name)"))
        }
    }
}

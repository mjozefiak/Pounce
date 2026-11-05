import Foundation
import LintelKit
import Testing

@testable import LintelApp

private let settingsRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources/LintelApp/Settings")

/// The main window's Advanced pane (step 6.5d): the Welcome and About rows call their closures, the reset
/// confirmation keeps Cancel as the default button, and the old window's pane stays as it was.
@MainActor
@Suite struct AdvancedPaneFidelityTests {
    @Test func theWelcomeAndAboutClosuresAreCalled() {
        var welcome = 0
        var about = 0
        let controls = AdvancedControls(
            usage: InMemoryUsageRecorder(), showWelcome: { welcome += 1 }, showAbout: { about += 1 }, version: "1.0",
            onReset: {})
        controls.showWelcome()
        controls.showAbout()
        controls.showAbout()
        #expect(welcome == 1)
        #expect(about == 2)
    }

    @Test func theAboutRowNamesTheVersionOrJustTheLicences() {
        #expect(
            AdvancedControls(usage: InMemoryUsageRecorder(), version: "1.0", onReset: {}).aboutDetail
                == "Version 1.0 · licences")
        #expect(AdvancedControls(usage: InMemoryUsageRecorder(), version: nil, onReset: {}).aboutDetail == "Licences")
    }

    @Test func theMainWindowBranchHasTheThreeRowsAndTheTokens() throws {
        let source = try String(contentsOf: settingsRoot.appending(path: "AdvancedPane.swift"), encoding: .utf8)
        let main = try #require(source.components(separatedBy: "struct AdvancedPaneContent").last)
        #expect(main.contains("SettingsPane {"))
        #expect(main.contains("controls.showWelcome"))
        #expect(main.contains("controls.showAbout"))
        #expect(main.contains(".lintelDestructiveButton()"))
        #expect(main.contains("textSize.font(.body)"))
        #expect(main.contains("textSize.font(.callout)"))
        // No section header and no banner of its own: the host titles the pane.
        #expect(!main.contains("header:"))
        #expect(!main.contains(" .font(.callout)"))
    }

    @Test func theResetConfirmationCancelsByDefault() throws {
        let sheet = try String(
            contentsOf: settingsRoot.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "LintelUI/Components/ConfirmSheet.swift"), encoding: .utf8)
        #expect(sheet.contains(".keyboardShortcut(.defaultAction)"))
        #expect(AdvancedPane.confirmation.confirmTitle.key == "Reset Ranking")
    }

    @Test func theOldWindowKeepsItsOwnPane() throws {
        let legacy = try String(contentsOf: settingsRoot.appending(path: "LegacyShellPanes.swift"), encoding: .utf8)
        let pane = try #require(legacy.components(separatedBy: "struct LegacyAdvancedPane").last)
        #expect(pane.contains("Text(\"Ranking\""))
        #expect(pane.contains("App suggestions keep their own history"))
        #expect(pane.contains("Text(\"Advanced\", comment: \"Settings section title\")"))
        let source = try String(contentsOf: settingsRoot.appending(path: "AdvancedPane.swift"), encoding: .utf8)
        #expect(source.contains("hostStyle == .legacyWindow"))
        #expect(source.contains("LegacyAdvancedPane(controls: controls)"))
    }
}

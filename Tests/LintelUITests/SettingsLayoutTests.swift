import Foundation
import Testing

@testable import LintelUI

@Suite("Settings layout")
struct SettingsLayoutTests {
    @Test func cardsAreTheColumnMinusTheInsets() {
        #expect(SettingsLayout.cardWidth == SettingsLayout.columnWidth - 2 * SettingsLayout.cardInset)
        #expect(SettingsLayout.mainCardWidth == SettingsLayout.mainColumnWidth - 2 * SettingsLayout.cardInset)
    }

    /// The old window keeps its 600 pt panes; the main window's cards are the prototype's 640 pt
    /// (`layout.settingsContent`).
    @Test func theOldWindowKeepsItsWidthAndTheMainWindowMatchesThePrototype() {
        #expect(SettingsLayout.columnWidth == 600)
        #expect(SettingsLayout.mainCardWidth == 640)
    }

    @Test func thePaneTitleIsTwentyPointsAtMedium() {
        #expect(22 * TextSize.paneTitleRatio == 20)
    }

    @Test func paneFramesUseTheSharedColumn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in [
            "Sources/LintelApp/Settings/LegacyShellPanes.swift",
            "Sources/LintelApp/Settings/PermissionsPane.swift",
            "Sources/AppsPlugin/LegacyAppsSettingsPane.swift",
            "Sources/ClipboardPlugin/LegacyClipboardSettingsPane.swift",
        ] {
            let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            #expect(!text.contains(".frame(width: 600)"), "\(path)")
            #expect(text.contains("SettingsLayout.columnWidth"), "\(path)")
        }
    }
}

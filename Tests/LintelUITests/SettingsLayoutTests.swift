import Foundation
import Testing

@testable import LintelUI

@Suite("Settings layout")
struct SettingsLayoutTests {
    @Test func cardsAreTheColumnMinusTheInsets() {
        #expect(SettingsLayout.cardWidth == SettingsLayout.columnWidth - 2 * SettingsLayout.cardInset)
    }

    @Test func paneFramesUseTheSharedColumn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in [
            "Sources/LintelApp/Settings/GeneralPane.swift", "Sources/LintelApp/Settings/FeaturesPane.swift",
            "Sources/LintelApp/Settings/AdvancedPane.swift", "Sources/LintelApp/Settings/PermissionsPane.swift",
            "Sources/AppsPlugin/AppsSettings.swift", "Sources/ClipboardPlugin/ClipboardSettingsPane.swift",
        ] {
            let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            #expect(!text.contains(".frame(width: 600)"), "\(path)")
            #expect(text.contains("SettingsLayout.columnWidth"), "\(path)")
        }
    }
}

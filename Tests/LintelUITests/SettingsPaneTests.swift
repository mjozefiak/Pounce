import AppKit
import LintelUI
import SwiftUI
import Testing

@MainActor
@Suite struct SettingsPaneTests {
    private func size(_ view: some View) throws -> NSSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.nsImage).size
    }

    @Test func aPaneRendersWithAndWithoutAdvancedAndData() throws {
        let basicsOnly = SettingsPane { Text(verbatim: "Basics") }
        let full = SettingsPane {
            Text(verbatim: "Basics")
        } advanced: {
            Text(verbatim: "Advanced")
        } data: {
            Text(verbatim: "Data")
        }
        #expect(try size(basicsOnly.frame(width: 400, height: 300)).width > 0)
        #expect(try size(full.frame(width: 400, height: 300)).width > 0)
    }

    @Test func aFooterAndAConfirmSheetRender() throws {
        let footer = SettingsFooter("Stays on this Mac.").lintelTextSize(.extraLarge)
        #expect(try size(footer).height > 0)
        let sheet = ConfirmSheet(
            prompt: "Erase all history?", detail: "It cannot be undone.", confirmTitle: "Erase",
            onConfirm: {}, onCancel: {})
        #expect(try size(sheet).width >= 380)
    }

    @Test func footerLimitMatchesTheScanningRule() {
        #expect(SettingsFooter.maxLength == 140)
    }
}

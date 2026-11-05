import Foundation
import LintelUI
import Testing

/// Step 6.5b: secondary (ink) and destructive (red) buttons of the main window, structure and contrast.
@Suite struct ButtonStyleTests {
    private static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
    }

    @Test func destructiveTextIsReadableOnTheButtonFill() {
        // Card fills: white in the light theme, the darkest brand surface in the dark one (the worst case).
        #expect(BrandPalette.contrast(BrandPalette.statusErrorLight, 0xFFFFFF) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.statusErrorDark, BrandPalette.surfaceDark) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.inkLight, 0xFFFFFF) >= 7)
        #expect(BrandPalette.contrast(BrandPalette.inkDark, BrandPalette.surfaceDark) >= 7)
    }

    @Test func theMainWindowHostAppliesTheSecondaryStyle() throws {
        let host = try source("Sources/LintelApp/Window/MainWindowController.swift")
        #expect(host.contains(".buttonStyle(LintelSecondaryButtonStyle())"))
        let picker = try source("Sources/LintelUI/Components/MenuPicker.swift")
        #expect(picker.contains(".lintelSecondaryTint()"))
        let styles = try source("Sources/LintelUI/Components/SecondaryButtonStyles.swift")
        #expect(styles.contains("case .legacyWindow: content"))
    }

    @Test func everyDestructiveButtonUsesTheSharedStyle() throws {
        let files = [
            "Sources/ClipboardPlugin/ClipboardSettingsPane.swift",
            "Sources/DictationPlugin/DictationSettingsPane.swift",
            "Sources/MeetingsPlugin/UI/MeetingsSettingsPane.swift", "Sources/LintelApp/Settings/FeaturesPane.swift",
            "Sources/LintelApp/Settings/AdvancedPane.swift", "Sources/AppsPlugin/AppsSettingsPane.swift",
        ]
        for file in files {
            #expect(try source(file).contains(".lintelDestructiveButton()"), "\(file)")
        }
        let meetings = try source("Sources/MeetingsPlugin/UI/MeetingsSettingsPane.swift")
        #expect(meetings.components(separatedBy: ".lintelDestructiveButton()").count - 1 >= 2)
        let sheet = try source("Sources/LintelUI/Components/ConfirmSheet.swift")
        #expect(sheet.contains(".buttonStyle(LintelDestructiveButtonStyle())"))
        #expect(sheet.contains(".keyboardShortcut(.defaultAction)"))
    }

    @Test func confirmationsSayItCannotBeUndoneTheSameWay() throws {
        for file in [
            "Sources/ClipboardPlugin/ClipboardSettingsPane.swift", "Sources/DictationPlugin/DictationViews.swift",
            "Sources/MeetingsPlugin/UI/MeetingsViews.swift", "Sources/LintelApp/Settings/AdvancedPane.swift",
            "Sources/AppsPlugin/AppsSettingsPane.swift",
        ] {
            let text = try source(file)
            #expect(!text.contains("cannot be undone"), "\(file)")
            #expect(text.contains("can’t be undone"), "\(file)")
        }
    }
}

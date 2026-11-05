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
        #expect(sheet.contains(".buttonStyle(LintelDestructiveProminentButtonStyle())"))
        #expect(sheet.contains(".keyboardShortcut(.defaultAction)"))
        let models = try source("Sources/LintelApp/Settings/Models/ModelRow.swift")
        #expect(models.contains(".buttonStyle(LintelDestructiveButtonStyle())"))
    }

    /// The filled confirm button: `onStatus` text on the `status.error` fill keeps 4.5:1 in both appearances.
    @Test func theFilledDestructiveButtonIsReadable() {
        #expect(BrandPalette.contrast(BrandPalette.onStatusLight, BrandPalette.statusErrorLight) >= 4.5)
        #expect(BrandPalette.contrast(BrandPalette.onStatusDark, BrandPalette.statusErrorDark) >= 4.5)
    }

    /// Every plain menu picker of the main window takes the ink tint (a no-op under `.legacyWindow`).
    @Test func plainMenuPickersTakeTheSecondaryTint() throws {
        for (file, minimum) in [
            ("Sources/LintelApp/Settings/GeneralPane.swift", 1),
            ("Sources/ClipboardPlugin/ClipboardSettingsPane.swift", 2),
            ("Sources/DictationPlugin/DictationSettingsPane.swift", 1),
            ("Sources/MeetingsPlugin/UI/MeetingsSettingsPane.swift", 1),
        ] {
            #expect(try source(file).components(separatedBy: ".lintelSecondaryTint()").count - 1 >= minimum, "\(file)")
        }
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

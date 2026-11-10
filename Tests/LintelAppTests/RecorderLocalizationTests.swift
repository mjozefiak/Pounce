import Foundation
import Testing

/// QA N5: the shortcut recorder's placeholder ("Record Shortcut") stayed English in Polish because the
/// KeyboardShortcuts library ships no Polish. Our Polish strings are copied into the library's resource bundle by
/// `scripts/make-app.sh`; this keeps the file complete and the copy in place.
@Suite struct RecorderLocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theLibrarysRecorderStringsHaveARealPolishTranslation() throws {
        let url = Self.root.appending(path: "Resources/KeyboardShortcuts/pl.lproj/Localizable.strings")
        let strings = try #require(NSDictionary(contentsOf: url) as? [String: String])
        // The two keys the recorder uses in KeyboardShortcuts 1.10.0 (pinned exactly in Package.swift).
        let english = [
            "record_shortcut": "Record Shortcut", "press_shortcut": "Press Shortcut",
            "keyboard_shortcut_used_by_menu_item": "", "keyboard_shortcut_used_by_system": "",
            "keyboard_shortcuts_can_be_changed": "",
        ]
        for (key, english) in english {
            let polish = try #require(strings[key], "\(key) has no Polish string")
            #expect(!polish.isEmpty && polish != english)
        }
    }

    @Test func theBuildScriptPutsThePolishFileIntoTheLibrarysBundle() throws {
        let script = try String(contentsOf: Self.root.appending(path: "scripts/make-app.sh"), encoding: .utf8)
        #expect(script.contains("Resources/KeyboardShortcuts/pl.lproj/Localizable.strings"))
        #expect(script.contains("KeyboardShortcuts_KeyboardShortcuts.bundle/Contents/Resources/pl.lproj"))
        // The build itself fails when the file is not in the built bundle (the DMG job runs this script), so a
        // release without the Polish recorder strings cannot be produced.
        #expect(script.contains("did not reach the KeyboardShortcuts bundle"))
    }
}

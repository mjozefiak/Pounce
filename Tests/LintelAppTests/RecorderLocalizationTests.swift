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
        // The build itself fails when the file in the FINISHED bundle differs from ours (the DMG job runs this
        // script), so a release without the Polish recorder strings cannot be produced. The check must come after
        // signing and compare against the built path, not the copy's own destination.
        let check = try #require(script.range(of: "did not reach the built KeyboardShortcuts bundle"))
        let signing = try #require(script.range(of: "codesign --verify --strict --deep"))
        #expect(signing.upperBound < check.lowerBound)
        #expect(script.contains("cmp -s Resources/KeyboardShortcuts/pl.lproj/Localizable.strings"))
    }

    /// QA round 4: a QA helper that matched "Lintel" by name closed the owner's real window. A debug bundle is a
    /// different app: its own bundle id, executable and no document type; the release path is unchanged.
    @Test func theDebugBundleIsADifferentAppFromTheRealOne() throws {
        let script = try String(contentsOf: Self.root.appending(path: "scripts/make-app.sh"), encoding: .utf8)
        #expect(script.contains("BUNDLE_ID=\"com.lintelapp.Lintel.QA\""))
        #expect(script.contains("EXEC_NAME=\"Lintel-QA\""))
        // Another path, so a debug build never replaces the release bundle the DMG is made from.
        #expect(script.contains("OUT=\"$ROOT/dist/$APP_NAME-QA.app\""))
        #expect(script.contains("Delete :CFBundleDocumentTypes"))
        #expect(script.contains("Delete :UTExportedTypeDeclarations"))
        #expect(script.contains("--identifier \"$BUNDLE_ID\""))
        // Release keeps the real identity: the defaults are set before the debug branch changes them.
        let release = try #require(script.range(of: "BUNDLE_ID=\"com.lintelapp.Lintel\""))
        let debug = try #require(script.range(of: "BUNDLE_ID=\"com.lintelapp.Lintel.QA\""))
        #expect(release.upperBound < debug.lowerBound)
        let plist = try String(contentsOf: Self.root.appending(path: "Resources/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<string>com.lintelapp.Lintel</string>"))
        let settings = try String(
            contentsOf: Self.root.appending(path: "Sources/WindowsPlugin/WindowsSettings.swift"), encoding: .utf8)
        #expect(settings.contains("\"com.lintelapp.Lintel\", \"com.lintelapp.Lintel.QA\""))
    }
}

import Foundation
import Testing

/// Spec `2026-11-04-lintel-main-window`, UI/UX rules (step 2.3): source-scanning versions of the `.uxproof`
/// guards, so CI can run them. They cover `Sources/LintelUI/`, `Sources/LintelApp/Settings/` and the view files
/// of every plugin pane on the `SettingsPane` template.
@Suite struct SettingsSourceScanTests {
    /// View files of plugin panes that use the template (complete since step 5.3). Paths are relative to the
    /// repository root.
    static let migratedPluginPaneFiles: [String] = [
        "Sources/AppsPlugin/AppsSettingsPane.swift",
        "Sources/FilesPlugin/FilesSettingsPane.swift",
        "Sources/ClipboardPlugin/ClipboardSettingsPane.swift",
        "Sources/DictationPlugin/DictationSettingsPane.swift",
        "Sources/MeetingsPlugin/UI/MeetingsSettingsPane.swift",
    ]

    static let rawStatusColour =
        #/(foregroundStyle|foregroundColor|fill|stroke|background|tint)\(\.(orange|red|green|yellow|blue|purple|pink|teal|mint|indigo|cyan)\)|Color\.(orange|red|green|yellow|blue)(?![A-Za-z0-9])|\.system(Red|Orange|Green|Yellow|Blue)(?![A-Za-z0-9])/#
    static let hardCodedFont =
        #/[\s)]\.font\(\.(callout|caption|caption2|footnote|title|title2|title3|headline|subheadline|body|largeTitle)(?![A-Za-z0-9])/#
    static let glass = #/glassEffect|NSGlassEffectView/#
    static let longFooter = #/(comment|SettingsFooter\()\s*:?\s*"[^"]{140,}"/#

    private var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(under path: String) -> [URL] {
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The scanned files.
    private func scanned() -> [URL] {
        swiftFiles(under: "Sources/LintelUI") + swiftFiles(under: "Sources/LintelApp/Settings")
            + Self.migratedPluginPaneFiles.map { root.appending(path: $0) }
    }

    /// The text without `//` comments.
    static func strippingComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    private func violations(of pattern: Regex<AnyRegexOutput>) throws -> [String] {
        var found: [String] = []
        for url in scanned() {
            let text = Self.strippingComments(try String(contentsOf: url, encoding: .utf8))
            if text.contains(pattern) { found.append(url.lastPathComponent) }
        }
        return found
    }

    @Test func thereAreFilesToScan() {
        #expect(scanned().count >= 5)
        for path in Self.migratedPluginPaneFiles {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: path).path), "\(path)")
        }
    }

    @Test func noRawStatusColours() throws {
        #expect(try violations(of: Regex(Self.rawStatusColour)) == [])
    }

    @Test func textGoesThroughTheTextSizeTokens() throws {
        #expect(try violations(of: Regex(Self.hardCodedFont)) == [])
    }

    @Test func noGlassInSettings() throws {
        #expect(try violations(of: Regex(Self.glass)) == [])
    }

    @Test func noLongFooter() throws {
        #expect(try violations(of: Regex(Self.longFooter)) == [])
    }

    // The scanners themselves.

    @Test func theRulesCatchWhatTheyShould() {
        #expect("x.foregroundStyle(.orange)".contains(Self.rawStatusColour))
        #expect("Color.red".contains(Self.rawStatusColour))
        #expect(!"x.foregroundStyle(.secondary)".contains(Self.rawStatusColour))
        #expect("x.foregroundColor(.red)".contains(Self.rawStatusColour))
        #expect("Circle().fill(.orange)".contains(Self.rawStatusColour))
        #expect("x.background(.red)".contains(Self.rawStatusColour))
        #expect("Color(nsColor: .systemRed)".contains(Self.rawStatusColour))
        #expect(!"Circle().fill(.secondary)".contains(Self.rawStatusColour))
        #expect(!"Color(nsColor: .secondaryLabelColor)".contains(Self.rawStatusColour))
        #expect(!"x.fill(LintelBrand.statusError)".contains(Self.rawStatusColour))
        #expect("Text(a).font(.callout.weight(.medium))".contains(Self.hardCodedFont))
        #expect(!"x.font(textSize.font(.callout))".contains(Self.hardCodedFont))
        #expect("glassEffect(.regular)".contains(Self.glass))
        let long = String(repeating: "a", count: 141)
        #expect("SettingsFooter(\"\(long)\")".contains(Self.longFooter))
        #expect("comment: \"\(long)\"".contains(Self.longFooter))
        #expect(!"SettingsFooter(\"Short.\")".contains(Self.longFooter))
    }

    @Test func commentsAreSkipped() {
        let kept = Self.strippingComments("a.fill(.green) // not .orange\nb.fill(.red)")
        #expect(!kept.contains(".orange"))
        #expect(kept.contains(".green") && kept.contains(".red"))
    }
}

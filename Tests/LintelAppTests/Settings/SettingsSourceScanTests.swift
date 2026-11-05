import Foundation
import Testing

/// Spec `2026-11-04-lintel-main-window`, UI/UX rules (step 2.3): source-scanning versions of the `.uxproof`
/// guards, so CI can run them. They cover `Sources/LintelUI/`, `Sources/LintelApp/Settings/` and the view files
/// of every plugin pane already moved onto the `SettingsPane` template. Code under a `.legacyWindow` branch keeps
/// today's views and is skipped.
@Suite struct SettingsSourceScanTests {
    /// View files of plugin panes that use the template. Starts empty; every pane PR (Phases 4 and 5) adds its
    /// file, and the list is complete at step 5.3. Paths are relative to the repository root.
    static let migratedPluginPaneFiles: [String] = []

    /// Panes in `LintelApp/Settings` that still use today's fonts; each leaves this list in the Phase 4 step that
    /// moves it onto the template. The colour, footer and glass rules apply to them already.
    static let unmigratedAppPanes: Set<String> = [
        "GeneralPane.swift", "FeaturesPane.swift", "AdvancedPane.swift", "PermissionsPane.swift",
    ]

    static let rawStatusColour =
        #/foregroundStyle\(\.(orange|red|green|yellow|blue|purple|pink|teal|mint|indigo|cyan)\)|Color\.(orange|red|green|yellow|blue)(?![A-Za-z0-9])|\.tint\(\.(orange|red|green|yellow|blue)\)/#
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

    /// The scanned files and the rules that apply to each.
    private func scanned() -> [(url: URL, checksFonts: Bool)] {
        var result = swiftFiles(under: "Sources/LintelUI").map { ($0, true) }
        result += swiftFiles(under: "Sources/LintelApp/Settings").map {
            ($0, !Self.unmigratedAppPanes.contains($0.lastPathComponent))
        }
        result += Self.migratedPluginPaneFiles.map { (root.appending(path: $0), true) }
        return result
    }

    /// The text without the blocks that follow a `.legacyWindow` condition and without `//` comments.
    static func strippingLegacyBranches(_ source: String) -> String {
        var output = ""
        var skipDepth: Int?
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
            if skipDepth == nil, code.contains(".legacyWindow"), code.contains("{") {
                skipDepth = 0
            }
            if let depth = skipDepth {
                let next = depth + code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
                skipDepth = next <= 0 ? nil : next
                output += "\n"
                continue
            }
            output += code + "\n"
        }
        return output
    }

    private func violations(of pattern: Regex<AnyRegexOutput>, fonts: Bool = false) throws -> [String] {
        var found: [String] = []
        for (url, checksFonts) in scanned() where !fonts || checksFonts {
            let text = Self.strippingLegacyBranches(try String(contentsOf: url, encoding: .utf8))
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
        #expect(try violations(of: Regex(Self.hardCodedFont), fonts: true) == [])
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
        #expect("Text(a).font(.callout.weight(.medium))".contains(Self.hardCodedFont))
        #expect(!"x.font(textSize.font(.callout))".contains(Self.hardCodedFont))
        #expect("glassEffect(.regular)".contains(Self.glass))
        let long = String(repeating: "a", count: 141)
        #expect("SettingsFooter(\"\(long)\")".contains(Self.longFooter))
        #expect("comment: \"\(long)\"".contains(Self.longFooter))
        #expect(!"SettingsFooter(\"Short.\")".contains(Self.longFooter))
    }

    @Test func legacyBranchesAreSkipped() {
        let source = """
            if hostStyle == .legacyWindow {
                Text("a").foregroundStyle(.orange)
                if x { y }
            }
            Text("b").foregroundStyle(.red)
            """
        let kept = Self.strippingLegacyBranches(source)
        #expect(!kept.contains(".orange"))
        #expect(kept.contains(".red"))
    }
}

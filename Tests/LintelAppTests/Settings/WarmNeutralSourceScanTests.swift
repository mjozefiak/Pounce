import Foundation
import Testing

/// The main window, Settings, the welcome screen, `LintelUI` and the plugin settings panes draw their neutrals
/// from `LintelBrand` (the prototype's `--win`, `--side`, `--card`, `--sec`, `--hair`, `--fill`), never from the
/// cold system greys. The launcher panel (glass) and the HUDs are out of scope and are not scanned.
@Suite struct WarmNeutralSourceScanTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// System neutrals the scanned files must not use: the hierarchical `.secondary` / `.tertiary` /
    /// `.quaternary` styles, the AppKit greys and the system `Divider`.
    static let pattern =
        #"\.(secondary|tertiary|quaternary)\b|separatorColor|controlBackgroundColor|(?<!LintelBrand)\.windowBackgroundColor|(secondary|tertiary|quaternary)LabelColor|SystemFill\b|\bDivider\(\)"#

    static func usesSystemNeutral(_ code: String) -> Bool {
        code.range(of: pattern, options: .regularExpression) != nil
    }

    /// Documented exceptions: `"<path relative to the repository>": [needles allowed on a line]`. Empty today;
    /// the one surface that stays a system fill (the grouped form's section cards, which macOS draws itself) is
    /// not written in source and is described on `LintelFormSurfaces`.
    static let exceptions: [String: [String]] = [:]

    static func scannedFiles() throws -> [URL] {
        let folders = [
            "Sources/LintelApp/Settings", "Sources/LintelApp/Window", "Sources/LintelApp/Onboarding",
            "Sources/LintelUI",
        ]
        var files: [URL] = []
        for folder in folders {
            let url = root.appending(path: folder)
            let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" { files.append(file) }
        }
        let sources = root.appending(path: "Sources")
        for plugin in try FileManager.default.contentsOfDirectory(atPath: sources.path())
        where plugin.hasSuffix("Plugin") {
            let url = sources.appending(path: plugin)
            let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator
            where file.pathExtension == "swift" && file.lastPathComponent.contains("SettingsPane") {
                files.append(file)
            }
        }
        return files
    }

    @Test func noScannedFileUsesASystemNeutral() throws {
        let files = try Self.scannedFiles()
        // Settings, Window, Onboarding, LintelUI and the five plugin panes.
        #expect(files.count > 30)
        #expect(files.contains { $0.lastPathComponent == "MeetingsSettingsPane.swift" })
        var offences: [String] = []
        for file in files {
            let relative = String(file.path().dropFirst(Self.root.path().count))
            let allowed = Self.exceptions[relative] ?? []
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                // Comments may name the system colours they replace.
                let code = line.components(separatedBy: "//").first ?? ""
                guard Self.usesSystemNeutral(code), !allowed.contains(where: code.contains) else { continue }
                offences.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offences.isEmpty, "use LintelBrand.secondaryText / hairline / card / fill: \(offences)")
    }

    /// The pattern catches what it is meant to and leaves the brand tokens alone.
    @Test func thePatternMatchesTheSystemNeutralsOnly() {
        for bad in [
            ".foregroundStyle(.secondary)", "AnyShapeStyle(.tertiary)", ".background(.quaternary, in: Capsule())",
            "Color(nsColor: .separatorColor)", "Color(nsColor: .controlBackgroundColor)",
            "NSColor.windowBackgroundColor", "Color(nsColor: .secondaryLabelColor)",
            "Color(nsColor: .quaternarySystemFill)", "Divider()",
        ] {
            #expect(Self.usesSystemNeutral(bad), "\(bad)")
        }
        for good in [
            ".foregroundStyle(LintelBrand.secondaryText)", "LintelBrand.windowBackgroundColor", "LintelDivider()",
            "LintelBrand.hairline", "LintelBrand.fill", "LintelBrand.card",
        ] {
            #expect(!Self.usesSystemNeutral(good), "\(good)")
        }
    }
}

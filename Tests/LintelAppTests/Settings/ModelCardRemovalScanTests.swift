import Foundation
import Testing

/// Spec `2026-11-04-lintel-main-window`, step 3.3: in the main window the Dictation and Meetings panes show a
/// one-line model summary instead of the model cards and microphone rows (those live in the Models and
/// Permissions panes), and every way to a model download goes through `PluginContext.openModels`.
@Suite struct ModelCardRemovalScanTests {
    /// The views that only the old Settings window (`.legacyWindow`) may draw in a plugin pane.
    static let legacyOnlyViews = [
        "SpeechModelCard", "MeetingsModelCard", "BuiltInModelRows", "MicrophoneRows", "MeetingsMicrophoneRows",
    ]

    /// The pane views (file, struct) whose main-window branches are scanned.
    static let paneViews: [(file: String, type: String)] = [
        ("Sources/DictationPlugin/DictationViews.swift", "DictationSettingsPane"),
        ("Sources/DictationPlugin/DictationViews.swift", "FormattingSection"),
        ("Sources/MeetingsPlugin/UI/MeetingsViews.swift", "MeetingsSettingsPane"),
    ]

    /// Every call of a plugin's `openSettings` (`PluginContext.openSettings` and the closures it is passed on as),
    /// with why it does not lead to a model download. A new call fails `everyOpenSettingsCallIsListed` until it
    /// is listed here; one that leads to a download must use `openModels` instead.
    static let openSettingsCalls: [(file: String, line: String, reason: String)] = [
        (
            "Sources/DictationPlugin/DictationPlugin.swift", "let openSettings = context.openSettings",
            "the HUD's microphone link (model problems use onOpenModels)"
        ),
        (
            "Sources/DictationPlugin/DictationPlugin.swift",
            "onCancel: { relay.controller?.cancel() }, onOpenSettings: { openSettings() },",
            "the HUD's microphone-denied link"
        ),
        (
            "Sources/DictationPlugin/DictationPlugin.swift",
            "hud: hud, claimEscape: context.claimEscapeKey, openSettings: context.openSettings,",
            "a controller dependency the controller never calls"
        ),
        (
            "Sources/MeetingsPlugin/MeetingsPlugin.swift",
            "hud: hud, clock: context.clock, openSettings: context.openSettings,",
            "the HUD's system-audio and library-unavailable links (model problems use openModels)"
        ),
        (
            "Sources/MeetingsPlugin/Recording/MeetingController.swift", "case .openSettings: deps.openSettings()",
            "MeetingHUDState.Action.openSettings: system audio and the library, never a model"
        ),
        (
            "Sources/MeetingsPlugin/UI/MeetingsViews.swift", "openSettings()",
            "SystemAudioTestRows: the System Audio Recording privacy settings"
        ),
    ]

    /// `context.openSettings` and a call `openSettings()` (also `deps.openSettings()`), not `onOpenSettings`.
    static let openSettingsCall = #/context\.openSettings(?![A-Za-z0-9_])|(?:^|[^A-Za-z0-9_])openSettings\(\)/#

    private static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// The source of `struct <name>` up to its closing brace.
    static func declaration(of name: String, in source: String) -> String? {
        guard let start = source.range(of: "struct \(name):") ?? source.range(of: "struct \(name) ") else {
            return nil
        }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[start.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func mentions(_ name: String, in text: String) -> Bool {
        text.range(of: "(?<![A-Za-z0-9_])\(name)(?![A-Za-z0-9_])", options: .regularExpression) != nil
    }

    @Test func noMainWindowBranchReferencesTheModelCardsOrMicrophoneRows() throws {
        for (file, type) in Self.paneViews {
            let source = try #require(Self.declaration(of: type, in: try Self.read(file)), "\(type) in \(file)")
            let kept = SettingsSourceScanTests.strippingLegacyBranches(source)
            for name in Self.legacyOnlyViews {
                #expect(!Self.mentions(name, in: kept), "\(type) draws \(name) outside a .legacyWindow branch")
            }
            #expect(kept.contains("ModelChoiceRow"), "\(type) has no model summary in the main window")
        }
    }

    @Test func theOldWindowStillDrawsEveryCardAndRow() throws {
        let panes = try Self.paneViews.map { file, type in
            try #require(Self.declaration(of: type, in: try Self.read(file)))
        }
        .joined(separator: "\n")
        for name in Self.legacyOnlyViews {
            #expect(Self.mentions(name, in: panes), "\(name) is gone from the old window too")
        }
    }

    @Test func everyOpenSettingsCallIsListedAndNoneLeadsToAModelDownload() throws {
        var found: [(file: String, line: String)] = []
        for plugin in ["AppsPlugin", "FilesPlugin", "ClipboardPlugin", "DictationPlugin", "MeetingsPlugin"] {
            let folder = Self.root.appending(path: "Sources/\(plugin)", directoryHint: .isDirectory)
            let files =
                FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for url in files {
                let relative = String(url.path.dropFirst(Self.root.path.count + 1))
                for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                    let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
                    if code.contains(Self.openSettingsCall) {
                        found.append((relative, code.trimmingCharacters(in: .whitespaces)))
                    }
                }
            }
        }
        for call in found {
            let listed = Self.openSettingsCalls.contains { $0.file == call.file && $0.line == call.line }
            #expect(listed, "unlisted openSettings call in \(call.file): \(call.line)")
            #expect(
                call.line.range(of: #"(?i)model|download"#, options: .regularExpression) == nil,
                "openSettings next to a model in \(call.file): \(call.line); use openModels")
        }
        for entry in Self.openSettingsCalls {
            #expect(
                found.contains { $0.file == entry.file && $0.line == entry.line },
                "stale entry \(entry.file): \(entry.line)")
        }
    }

    /// The model download routes, one per place that offered "Open Settings" for a model before step 3.3.
    @Test func theModelRoutesUseOpenModels() throws {
        let routes: [(file: String, text: String)] = [
            ("Sources/DictationPlugin/DictationPlugin.swift", "onOpenModels: { openModels(settings.speechModelID) }"),
            ("Sources/DictationPlugin/DictationPlugin.swift", "openModels: context.openModels))"),
            ("Sources/MeetingsPlugin/MeetingsPlugin.swift", "openModels: context.openModels, changed:"),
            ("Sources/MeetingsPlugin/MeetingsPlugin.swift", "openNotesModel: { [openModels = context.openModels]"),
            ("Sources/MeetingsPlugin/MeetingsPlugin+Library.swift", "openNotesModel: { openModels("),
            ("Sources/MeetingsPlugin/MeetingsPlugin+Settings.swift", "openModels: context.openModels))"),
            ("Sources/MeetingsPlugin/Notes/NotesService.swift", "if job.requested { deps.openModels(model.id) }"),
            ("Sources/MeetingsPlugin/Recording/MeetingController.swift", "case .openModels: deps.openModels("),
        ]
        for route in routes {
            #expect(try Self.read(route.file).contains(route.text), "\(route.file): \(route.text)")
        }
    }

    @Test func theDeclarationScannerFindsTheWholeStruct() throws {
        let source = """
            struct A: View {
                var body: some View { if x { B() } }
            }
            struct C {}
            """
        let found = try #require(Self.declaration(of: "A", in: source))
        #expect(found.hasSuffix("}\n}"))
        #expect(!found.contains("struct C"))
    }
}

import Foundation
import Testing

/// Step 6.6f: every plugin's welcome page is the prototype's single column (`shell-welcome-*`). The step's
/// explanation is `OnboardingStep.text` (drawn by the shell under the heading, never again in the view) and the
/// view lays its controls out with `WelcomeStepColumn` / `WelcomeStepItem`: no icon column, no system greens,
/// oranges or greys. The Apps plugin has no onboarding step.
@Suite struct WelcomePluginPagesScanTests {
    struct Page {
        let file: String
        let view: String
        let plugin: String
        let lead: String
    }

    static let pages = [
        Page(
            file: "Sources/FilesPlugin/FilesViews.swift", view: "FilesOnboardingView",
            plugin: "Sources/FilesPlugin/FilesPlugin.swift",
            lead: "Lintel finds files and folders by name, using its own index that stays on this Mac."),
        Page(
            file: "Sources/ClipboardPlugin/ClipboardViews.swift", view: "ClipboardOnboardingView",
            plugin: "Sources/ClipboardPlugin/ClipboardPlugin.swift",
            lead: "Lintel keeps what you copy so you can paste it again with ⌘⇧V."),
        Page(
            file: "Sources/DictationPlugin/DictationViews.swift", view: "DictationSetupView",
            plugin: "Sources/DictationPlugin/DictationPlugin.swift",
            lead: "Dictate in any app: press the shortcut, talk, and Lintel types the text where you are."),
        Page(
            file: "Sources/MeetingsPlugin/UI/MeetingsViews.swift", view: "MeetingsSetupView",
            plugin: "Sources/MeetingsPlugin/MeetingsPlugin+Settings.swift",
            lead: "Record meetings and get a transcript with the speakers told apart."),
    ]

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

    /// The view's `body`, without the static `text` the step hands to the shell.
    private static func body(of page: Page) throws -> String {
        let declaration = try #require(
            ModelCardRemovalScanTests.declaration(of: page.view, in: try read(page.file)), "\(page.view)")
        let start = try #require(declaration.range(of: "var body: some View"), "\(page.view) has no body")
        return String(declaration[start.lowerBound...])
    }

    @Test func everyPageUsesTheSharedColumnAndNoIcons() throws {
        for page in Self.pages {
            let body = try Self.body(of: page)
            #expect(body.contains("WelcomeStepColumn"), "\(page.view) is not on the welcome column")
            #expect(body.contains("WelcomeStepItem"), "\(page.view) has no parts")
            for needle in ["Label {", "Image(systemName:", ".green", ".orange", ".secondary)"] {
                #expect(!body.contains(needle), "\(page.view) draws \(needle)")
            }
        }
        let suggestions = try #require(
            ModelCardRemovalScanTests.declaration(
                of: "MeetingsSuggestionsSetupPart",
                in: try Self.read("Sources/MeetingsPlugin/Suggestions/MeetingsSuggestionsViews.swift")))
        #expect(suggestions.contains("WelcomeStepItem"))
        #expect(!suggestions.contains("Image(systemName:"))
        #expect(!suggestions.contains(".orange"))
    }

    @Test func theExplanationIsTheStepTextAndIsNotRepeated() throws {
        for page in Self.pages {
            #expect(!(try Self.body(of: page)).contains(page.lead), "\(page.view) repeats the heading's line")
            let declaration = try #require(
                ModelCardRemovalScanTests.declaration(of: page.view, in: try Self.read(page.file)))
            #expect(declaration.contains("static let text = LocalizedStringResource("), "\(page.view)")
            #expect(declaration.contains(page.lead), "\(page.view)")
            #expect(try Self.read(page.plugin).contains("text: \(page.view).text"), "\(page.plugin)")
        }
    }

    @Test func theAppsPluginHasNoWelcomePage() throws {
        let folder = Self.root.appending(path: "Sources/AppsPlugin", directoryHint: .isDirectory)
        let files =
            FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for url in files {
            #expect(
                !(try String(contentsOf: url, encoding: .utf8)).contains("OnboardingStep("), "\(url.lastPathComponent)")
        }
    }
}

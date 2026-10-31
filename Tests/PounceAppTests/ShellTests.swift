import AppKit
import Foundation
import PounceKit
import Testing

@testable import PounceApp

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// Spec step 0.1 smoke test: the bundle's Info.plist describes a menu bar agent.
@Suite struct InfoPlistTests {
    @Test func describesTheAgentApp() throws {
        let data = try Data(contentsOf: repositoryRoot.appending(path: "Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(plist["CFBundleIdentifier"] as? String == "app.pounce.Pounce")
        #expect(plist["CFBundleExecutable"] as? String == "Pounce")
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(plist["CFBundleLocalizations"] as? [String] == ["en", "pl"])
        let version = try #require(plist["CFBundleShortVersionString"] as? String)
        #expect(version.split(separator: ".").count == 3)
    }
}

/// Every string in the catalog has a translated English and Polish value (Q11).
@Suite struct StringCatalogTests {
    struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct StringUnit: Decodable {
                    let state: String
                    let value: String
                }
                let stringUnit: StringUnit?
            }
            let localizations: [String: Localization]?
        }
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    @Test func everyStringHasEnglishAndPolish() throws {
        let data = try Data(contentsOf: repositoryRoot.appending(path: "Resources/Localizable.xcstrings"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        #expect(catalog.sourceLanguage == "en")
        #expect(!catalog.strings.isEmpty)
        for (key, entry) in catalog.strings {
            for language in ["en", "pl"] {
                let unit = entry.localizations?[language]?.stringUnit
                #expect(unit?.state == "translated", "\(key) is missing a translated \(language) value")
                #expect(unit?.value.isEmpty == false, "\(key) has an empty \(language) value")
            }
        }
    }

    @Test func menuStringsAreInTheCatalog() throws {
        let data = try Data(contentsOf: repositoryRoot.appending(path: "Resources/Localizable.xcstrings"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        for key in ["About Pounce", "Quit Pounce", "Pounce", "Pounce cannot start"] {
            #expect(catalog.strings[key] != nil, "\(key) is not in Localizable.xcstrings")
        }
        #expect(catalog.strings["Quit Pounce"]?.localizations?["pl"]?.stringUnit?.value == "Zakończ Pounce")
    }
}

@Suite struct StatusMenuTests {
    @Test func withoutPluginsTheMenuHasAboutAndQuit() {
        let menu = NSMenu()
        StatusMenuBuilder().populate(menu, commands: [])
        #expect(menu.items.map(\.title) == ["About Pounce", "", "Quit Pounce"])
        let quit = menu.items[2]
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == .command)
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
    }

    @Test func menuCommandsComeFirstAndHiddenOnesAreSkipped() {
        let menu = NSMenu()
        let commands = [
            PluginCommand(id: "a", title: "Clipboard History", symbolName: "doc.on.clipboard") {},
            PluginCommand(id: "b", title: "Hidden", showsInMenu: false) {},
        ]
        StatusMenuBuilder().populate(menu, commands: commands)
        #expect(menu.items.map(\.title) == ["Clipboard History", "", "About Pounce", "", "Quit Pounce"])
        #expect(menu.items[1].isSeparatorItem)
    }

    @Test func usesATemplateSymbol() throws {
        let image = try #require(
            NSImage(systemSymbolName: StatusItemController.symbolName, accessibilityDescription: nil))
        #expect(image.size.width > 0)
    }
}

@Suite struct KeychainClientTests {
    @Test func mapsStatusesToDistinctErrors() {
        #expect(KeychainStatus.error(for: errSecItemNotFound) == .itemNotFound)
        #expect(KeychainStatus.error(for: errSecInteractionNotAllowed) == .interactionNotAllowed)
        #expect(KeychainStatus.error(for: errSecAuthFailed) == .accessDenied)
        #expect(KeychainStatus.error(for: errSecUserCanceled) == .accessDenied)
        #expect(KeychainStatus.error(for: errSecDecode) == .unexpected(status: errSecDecode))
    }

    @Test func inMemoryKeychainRoundTrips() throws {
        let keychain = InMemoryKeychainClient()
        #expect(throws: KeychainError.itemNotFound) {
            _ = try keychain.readGenericPassword(service: "app.pounce.clipboard", account: "master")
        }
        try keychain.addGenericPassword(Data([1, 2, 3]), service: "app.pounce.clipboard", account: "master")
        #expect(throws: KeychainError.unexpected(status: errSecDuplicateItem)) {
            try keychain.addGenericPassword(Data([4]), service: "app.pounce.clipboard", account: "master")
        }
        #expect(
            try keychain.readGenericPassword(service: "app.pounce.clipboard", account: "master") == Data([1, 2, 3]))
        try keychain.deleteGenericPassword(service: "app.pounce.clipboard", account: "master")
        #expect(throws: KeychainError.itemNotFound) {
            try keychain.deleteGenericPassword(service: "app.pounce.clipboard", account: "master")
        }
    }
}

@Suite struct UsageRecorderTests {
    @Test func countsUsesAndQueryAssociations() async throws {
        let recorder = InMemoryUsageRecorder()
        let terminal = ItemKey(pluginID: "apps", key: "com.apple.Terminal")
        let date = Date(timeIntervalSince1970: 1_000)
        try await recorder.recordUse(of: terminal, queryPrefix: "te", at: date)
        try await recorder.recordUse(of: terminal, queryPrefix: "te", at: date)

        let stats = try await recorder.stats(for: [terminal], queryPrefix: "te")
        #expect(stats[terminal]?.useCount == 2)
        #expect(stats[terminal]?.queryAssociationCount == 2)
        #expect(stats[terminal]?.lastUsedAt == date)
        let other = try await recorder.stats(for: [ItemKey(pluginID: "apps", key: "x")], queryPrefix: nil)
        #expect(other.isEmpty)
    }
}

#if DEBUG
@Suite struct QAOptionsTests {
    @Test func noQAArgumentsMeansNormalMode() throws {
        #expect(try QAOptions.parse(["Pounce", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    @Test func parsesEveryOption() throws {
        let options = try #require(
            try QAOptions.parse([
                "Pounce", "--qa", "--qa-data-root", "/tmp/pounce-qa", "--qa-appearance", "dark",
                "--qa-show-menu", "--qa-quit-after", "2.5",
            ])
        )
        #expect(options.dataRoot?.path == "/tmp/pounce-qa")
        #expect(options.appearance == .dark)
        #expect(options.showsMenu)
        #expect(options.quitAfter == .milliseconds(2500))
    }

    @Test func anyQAArgumentEnablesQAMode() throws {
        let options = try #require(try QAOptions.parse(["Pounce", "--qa-show-menu"]))
        #expect(options.showsMenu)
        #expect(options.dataRoot == nil)
    }

    @Test func rejectsBadValues() {
        #expect(throws: QAOptions.ParseError.invalidValue("--qa-appearance", "sepia")) {
            _ = try QAOptions.parse(["--qa-appearance", "sepia"])
        }
        #expect(throws: QAOptions.ParseError.missingValue("--qa-data-root")) {
            _ = try QAOptions.parse(["--qa-data-root"])
        }
        #expect(throws: QAOptions.ParseError.unknownArgument("--qa-steal-hotkey")) {
            _ = try QAOptions.parse(["--qa-steal-hotkey"])
        }
    }

    @Test func qaEnvironmentIsolatesUserData() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pounce-qa-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment.qa(QAOptions(dataRoot: root))
        defer { environment.defaults.removePersistentDomain(forName: AppEnvironment.qaDefaultsSuite) }

        #expect(environment.dataRoot == root)
        #expect(environment.keychain is InMemoryKeychainClient)
        #expect(environment.pasteboardName != nil)
        #expect(!environment.registersGlobalHotkeys)
        #expect(environment.volatileDefaultsSuite == AppEnvironment.qaDefaultsSuite)
        #expect(environment.storageDirectory(for: "clipboard").path.hasPrefix(root.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}
#endif

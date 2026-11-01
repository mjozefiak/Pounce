import Foundation
import PounceKit
import Testing

@testable import AppsPlugin

/// Spec step 1.3: the directory scan, helpers nested in bundles, duplicates and aliases.
@Suite struct AppScannerTests {
    @Test func scansTwoLevelsAndSkipsNestedHelpersAndInvalidBundles() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.makeApp("Main/Notes.app", identifier: "com.example.notes")
        try fixture.makeApp("Main/Utilities/Disk Tool.app", identifier: "com.example.disktool")
        try fixture.makeApp("Main/A/B/Too Deep.app", identifier: "com.example.deep")
        try fixture.makeApp("Main/Notes.app/Contents/Helpers/Notes Helper.app", identifier: "com.example.helper")
        try fixture.makeApp("Main/No Identifier.app", identifier: nil)
        try fixture.makeApp("Main/Agent.app", identifier: "com.example.agent", extra: ["LSBackgroundOnly": true])

        let scanner = AppScanner(roots: [fixture.url("Main")], displayName: fileNameDisplayName)
        let records = try scanner.scan()
        #expect(records.map(\.bundleIdentifier) == ["com.example.notes", "com.example.disktool"])
        #expect(records.map(\.name) == ["Notes", "Disk Tool"])
    }

    @Test func deduplicatesByBundleIdentifierPreferringTheFirstRoot() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.makeApp("Applications/Editor.app", identifier: "com.example.editor")
        try fixture.makeApp("User/Editor Copy.app", identifier: "com.example.editor")
        try fixture.makeApp("User/Mail.app", identifier: "com.example.mail")

        let scanner = AppScanner(
            roots: [fixture.url("Applications"), fixture.url("User")],
            displayName: fileNameDisplayName
        )
        let apps = AppCatalog.deduplicate(try scanner.scan())
        #expect(apps.map(\.bundleIdentifier) == ["com.example.editor", "com.example.mail"])
        #expect(apps[0].path.hasSuffix("/Applications/Editor.app"))
    }

    @Test func aliasesComeFromBundleNamesAndTheFileName() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let bundle = try fixture.makeApp(
            "Apps/Visual Studio Code.app",
            identifier: "com.microsoft.VSCode",
            name: "Code",
            displayName: "Visual Studio Code"
        )
        let localized = AppScanner(roots: [], displayName: { _ in "Kalkulator" }).record(at: bundle)
        #expect(localized?.name == "Kalkulator")
        #expect(localized?.aliases == ["Visual Studio Code", "Code"])

        let plain = AppScanner(roots: [], displayName: fileNameDisplayName).record(at: bundle)
        #expect(plain?.name == "Visual Studio Code")
        #expect(plain?.aliases == ["Code"])
    }

    @Test func pathFilterRejectsNestedHiddenAndExternalBundles() {
        #expect(AppPathFilter.isEligible("/Applications/Safari.app"))
        #expect(AppPathFilter.isEligible("/Applications/Utilities/Terminal.app"))
        #expect(!AppPathFilter.isEligible("/Applications/Xcode.app/Contents/Developer/Simulator.app"))
        #expect(!AppPathFilter.isEligible("/Volumes/Backup/Applications/Old.app"))
        #expect(!AppPathFilter.isEligible("/Users/me/.Trash/Gone.app"))
        #expect(!AppPathFilter.isEligible("/Users/me/Library/Developer/Xcode/DerivedData/X/Build/Demo.app"))
        #expect(!AppPathFilter.isEligible("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"))
        #expect(!AppPathFilter.isEligible("/Applications/Notes"))
        #expect(!AppPathFilter.isEligible("relative/Notes.app"))
    }

    @Test func defaultRootsPreferApplications() {
        let roots = AppScanner.defaultRoots(home: URL(filePath: "/Users/me", directoryHint: .isDirectory))
        #expect(
            roots.map(\.path) == [
                "/Applications",
                "/Users/me/Applications",
                "/System/Applications",
                "/System/Library/CoreServices/Applications",
            ])
    }

    @Test func cacheRoundTripsAndIgnoresUnknownVersions() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let cache = AppCache(directory: fixture.url("Caches"))
        #expect(cache.load() == nil)
        let records = [AppRecord(bundleIdentifier: "com.example.a", path: "/Applications/A.app", name: "A")]
        try cache.save(records)
        #expect(cache.load() == records)
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try Data(#"{"version":99,"apps":[]}"#.utf8).write(to: cache.url)
        #expect(cache.load() == nil)
    }
}

import Foundation
import Testing

@testable import FilesPlugin

@Suite struct ScannerTests {
    /// Spec step 3.1: a fixture tree with a package, a symlink and `node_modules` gives the expected list.
    @Test func fixtureTreeGivesTheExpectedList() throws {
        let tree = try TemporaryDirectory().make([
            "Notes/plan.txt",
            "Notes/Archive/old plan.md",
            "Demo.app/Contents/Info.plist",
            "Photos Demo.photoslibrary/database/db.sqlite",
            "project/node_modules/left-pad/index.js",
            "project/src/main.swift",
            "project/.git/HEAD",
            ".hidden-config",
            "Empty/",
        ])
        try FileManager.default.createSymbolicLink(
            atPath: tree.sub("link-to-notes"), withDestinationPath: tree.sub("Notes"))

        let collector = ListingCollector()
        let rules = IgnoreRules.make(home: "/nonexistent-home", userExclusions: [], includesHidden: false)
        let finished = BulkScanner(rules: rules, workerCount: 4, batchSize: 2).scan(tree.path) { collector.add($0) }

        #expect(finished)
        #expect(collector.parentsFirst)
        #expect(
            collector.found == [
                "Notes": .directory,
                "Notes/plan.txt": .file,
                "Notes/Archive": .directory,
                "Notes/Archive/old plan.md": .file,
                "Demo.app": .package,
                "Photos Demo.photoslibrary": .package,
                "project": .directory,
                "project/src": .directory,
                "project/src/main.swift": .file,
                "link-to-notes": .symlink,
                "Empty": .directory,
            ])
    }

    @Test func hiddenItemsAndUserPatternsFollowTheRules() throws {
        let tree = try TemporaryDirectory().make([".zshrc", "build.tmp", "keep.txt", "Secret/inside.txt"])
        let rules = IgnoreRules.make(
            home: "/nonexistent-home", userExclusions: ["*.TMP", tree.sub("Secret")], includesHidden: true)
        let collector = ListingCollector()
        BulkScanner(rules: rules).scan(tree.path) { collector.add($0) }
        #expect(collector.found == [".zshrc": .file, "keep.txt": .file])
    }

    @Test func listReturnsOneLevel() throws {
        let tree = try TemporaryDirectory().make(["a.txt", "Folder/b.txt"])
        let entries = try #require(BulkScanner(rules: IgnoreRules()).list(tree.path))
        #expect(Set(entries.map(\.name)) == ["a.txt", "Folder"])
        #expect(entries.allSatisfy { $0.directoryID == nil })
        #expect(entries.allSatisfy { $0.modified > 1_600_000_000 })
        #expect(BulkScanner(rules: IgnoreRules()).list(tree.sub("missing")) == nil)
    }

    @Test func manyFilesAcrossBatches() throws {
        let tree = try TemporaryDirectory()
        try tree.make((0..<40).flatMap { folder in (0..<30).map { "d\(folder)/f\($0).txt" } })
        let collector = ListingCollector()
        BulkScanner(rules: IgnoreRules(), workerCount: 8, batchSize: 50).scan(tree.path) { collector.add($0) }
        #expect(collector.found.count == 40 + 40 * 30)
        #expect(collector.parentsFirst)
    }

    @Test func cancellationStopsTheScan() throws {
        let tree = try TemporaryDirectory()
        try tree.make((0..<50).map { "d\($0)/x/y/z.txt" })
        let collector = ListingCollector()
        let finished = BulkScanner(rules: IgnoreRules(), workerCount: 2).scan(
            tree.path, isCancelled: { true }, deliver: { collector.add($0) })
        #expect(!finished)
        #expect(collector.found.count < 50 * 4)
    }

    @Test func unreadableFolderIsSkipped() throws {
        let tree = try TemporaryDirectory().make(["Locked/secret.txt", "open.txt"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tree.sub("Locked"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.sub("Locked")) }
        let collector = ListingCollector()
        BulkScanner(rules: IgnoreRules()).scan(tree.path) { collector.add($0) }
        #expect(collector.found == ["Locked": .directory, "open.txt": .file])
    }
}

@Suite struct IgnoreRulesTests {
    let home = "/Users/demo"

    @Test func defaultsExcludeGeneratedFoldersLibraryAndHidden() {
        let rules = IgnoreRules.make(home: home, userExclusions: [], includesHidden: false)
        #expect(rules.excludes(name: "node_modules", path: "/Users/demo/p/node_modules"))
        #expect(rules.excludes(name: "DerivedData", path: "/Users/demo/x/DerivedData"))
        #expect(rules.excludes(name: "Library", path: "/Users/demo/Library"))
        #expect(!rules.excludes(name: "Library", path: "/Users/demo/Projects/Library"))
        #expect(rules.excludes(name: ".env", path: "/Users/demo/p/.env"))
        #expect(rules.excludes(name: "visible", path: "/Users/demo/visible", hiddenFlag: true))
        #expect(!rules.excludes(name: "notes.txt", path: "/Users/demo/notes.txt"))
    }

    /// Spec step 3.6: `IgnoreRules` built from the user's settings.
    @Test func userExclusionsAreNamesPatternsOrPaths() {
        let rules = IgnoreRules.make(
            home: home, userExclusions: ["Archive", "*.log", "~/Movies/Raw", "/opt/data", "  ", "relative/path"],
            includesHidden: true)
        #expect(rules.excludes(name: "Archive", path: "/Users/demo/a/Archive"))
        #expect(rules.excludes(name: "Server.LOG", path: "/Users/demo/Server.LOG"))
        #expect(rules.excludes(name: "Raw", path: "/Users/demo/Movies/Raw"))
        #expect(!rules.excludes(name: "Raw", path: "/Users/demo/Pictures/Raw"))
        #expect(rules.excludes(name: "data", path: "/opt/data"))
        #expect(!rules.excludes(name: ".env", path: "/Users/demo/.env"))
        #expect(rules.patterns == ["*.log"])
    }

    @Test func excludesBelowChecksEveryComponent() {
        let rules = IgnoreRules.make(home: home, userExclusions: [], includesHidden: false)
        #expect(rules.excludesBelow(root: home, path: "/Users/demo/p/node_modules/a/b.js"))
        #expect(rules.excludesBelow(root: home, path: "/Users/demo/Library/Mobile Documents/x"))
        #expect(
            !rules.excludesBelow(
                root: "/Users/demo/Library/Mobile Documents", path: "/Users/demo/Library/Mobile Documents/x"))
        #expect(!rules.excludesBelow(root: home, path: "/Users/demo/Documents/plan.txt"))
        #expect(!rules.excludesBelow(root: home, path: "/elsewhere/x"))
    }
}

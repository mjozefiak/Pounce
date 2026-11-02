import Foundation
import Testing

@testable import FilesPlugin

@Suite("Directory lister")
struct DirectoryListerTests {
    private func names(_ listing: DirectoryListing) -> [String: Bool] {
        guard case .listed(let entries, _) = listing else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.isHidden) })
    }

    @Test func listsOneLevelIncludingHiddenAndExcludedNames() throws {
        let directory = try TemporaryDirectory().make([
            "home/p/.ai/runs/run-1/PLAN.md", "home/p/node_modules/x.js", "home/p/readme.md", "home/p/.env",
        ])
        let lister = DirectoryLister(home: directory.sub("home"))
        #expect(
            names(lister.list(directory.sub("home/p"), fullDiskAccess: false))
                == [".ai": true, "node_modules": false, "readme.md": false, ".env": true])
        #expect(names(lister.list(directory.sub("home/p/.ai/runs"), fullDiskAccess: false)) == ["run-1": false])
    }

    @Test func protectedFolderIsNotOpenedWithoutFullDiskAccess() throws {
        let directory = try TemporaryDirectory().make(["home/Documents/a.txt"])
        let lister = DirectoryLister(home: directory.sub("home"))
        #expect(lister.list(directory.sub("home/Documents"), fullDiskAccess: false) == .protected)
        #expect(names(lister.list(directory.sub("home/Documents"), fullDiskAccess: true)) == ["a.txt": false])
    }

    @Test func missingFolderAndFile() throws {
        let directory = try TemporaryDirectory().make(["home/file.txt"])
        let lister = DirectoryLister(home: directory.sub("home"))
        #expect(lister.list(directory.sub("home/nope"), fullDiskAccess: false) == .missing)
        #expect(lister.list(directory.sub("home/file.txt"), fullDiskAccess: false) == .missing)
    }

    @Test func unreadableFolderIsDenied() throws {
        let directory = try TemporaryDirectory().make(["home/locked/a.txt"])
        let locked = directory.sub("home/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        #expect(DirectoryLister(home: directory.sub("home")).list(locked, fullDiskAccess: false) == .denied)
    }

    @Test func linkedFolderIsFollowed() throws {
        let directory = try TemporaryDirectory().make(["home/real/a.txt"])
        try FileManager.default.createSymbolicLink(atPath: directory.sub("home/link"), withDestinationPath: "real")
        let lister = DirectoryLister(home: directory.sub("home"))
        #expect(names(lister.list(directory.sub("home/link"), fullDiskAccess: false)) == ["a.txt": false])
    }

    @Test func largeFoldersAreCut() throws {
        let directory = try TemporaryDirectory().make((0..<5).map { "home/many/f\($0)" })
        let listing = DirectoryLister(home: directory.sub("home"), limit: 3).list(
            directory.sub("home/many"), fullDiskAccess: false)
        guard case .listed(let entries, let truncated) = listing else {
            Issue.record("not listed")
            return
        }
        #expect(entries.count == 3)
        #expect(truncated)
    }

    @Test func cacheIsRefreshedWhenTheFolderChanges() throws {
        let directory = try TemporaryDirectory().make(["home/d/a.txt"])
        let lister = DirectoryLister(home: directory.sub("home"))
        #expect(names(lister.list(directory.sub("home/d"), fullDiskAccess: false)).keys.sorted() == ["a.txt"])
        try directory.make(["home/d/b.txt"])
        // Force a different modification time even on a coarse clock.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: directory.sub("home/d"))
        #expect(names(lister.list(directory.sub("home/d"), fullDiskAccess: false)).keys.sorted() == ["a.txt", "b.txt"])
    }
}

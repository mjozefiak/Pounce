import Foundation
import LintelCore
import LintelPersistence
import Testing

@testable import FilesPlugin

@Suite("TCC path resolver")
struct TCCPathResolverTests {
    @Test func resolvesExistingPathsAndLinks() throws {
        let directory = try TemporaryDirectory().make(["home/Projects/app/", "home/notes.txt"])
        let home = directory.sub("home")
        let real = try #require(TCCPathResolver.realPath(home))
        try FileManager.default.createSymbolicLink(atPath: directory.sub("home/p"), withDestinationPath: "Projects")
        #expect(
            TCCPathResolver.resolve(home + "/p/app", home: home, fullDiskAccess: false)
                == .resolved(real + "/Projects/app"))
        #expect(
            TCCPathResolver.resolve(home + "/nothing/here", home: home, fullDiskAccess: false) == .missing)
    }

    @Test func linkIntoAProtectedFolderStopsBeforeReadingInside() throws {
        let directory = try TemporaryDirectory().make(["home/Documents/secret/"])
        let home = directory.sub("home")
        let real = try #require(TCCPathResolver.realPath(home))
        // An absolute link target, as written by the user (it may go through `/var` → `/private/var`).
        try FileManager.default.createSymbolicLink(
            atPath: directory.sub("home/docs"), withDestinationPath: directory.sub("home/Documents/secret"))
        #expect(
            TCCPathResolver.resolve(home + "/docs", home: home, fullDiskAccess: false)
                == .protected(real + "/Documents"))
        #expect(
            TCCPathResolver.resolve(real + "/Documents/secret", home: home, fullDiskAccess: false)
                == .protected(real + "/Documents"))
        #expect(
            TCCPathResolver.resolve(home + "/docs", home: home, fullDiskAccess: true)
                == .resolved(real + "/Documents/secret"))
    }

    @Test func linkLoopsCountAsMissing() throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.createSymbolicLink(atPath: directory.sub("a"), withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(atPath: directory.sub("b"), withDestinationPath: "a")
        #expect(
            TCCPathResolver.resolve(directory.sub("a"), home: directory.path, fullDiskAccess: false) == .missing)
    }

    @Test func caseVariantOnDiskStopsAtTheFolder() throws {
        let directory = try TemporaryDirectory().make(["home/Documents/secret/"])
        let home = directory.sub("home")
        let real = try #require(TCCPathResolver.realPath(home))
        // The temporary volume is case-insensitive like the boot volume, so `documents` is `Documents`.
        let result = TCCPathResolver.resolve(home + "/documents/secret", home: home, fullDiskAccess: false)
        #expect(result == .protected(real + "/documents"))
    }

    @Test func relativeLinkWithDotDotIntoAProtectedFolderIsProtected() throws {
        let directory = try TemporaryDirectory().make(["home/Projects/", "home/Documents/x/"])
        let home = directory.sub("home")
        let real = try #require(TCCPathResolver.realPath(home))
        try FileManager.default.createSymbolicLink(
            atPath: directory.sub("home/Projects/docs"), withDestinationPath: "../Documents/x")
        #expect(
            TCCPathResolver.resolve(home + "/Projects/docs", home: home, fullDiskAccess: false)
                == .protected(real + "/Documents"))
    }

    @Test func homeReachedThroughALinkKeepsItsProtection() throws {
        let directory = try TemporaryDirectory().make(["realhome/Documents/x/"])
        try FileManager.default.createSymbolicLink(atPath: directory.sub("home"), withDestinationPath: "realhome")
        let home = directory.sub("home")
        let realHome = try #require(TCCPathResolver.realPath(directory.sub("realhome")))
        #expect(
            TCCPathResolver.resolve(home + "/Documents/x", home: home, fullDiskAccess: false)
                == .protected(realHome + "/Documents"))
    }

    @Test func protectedFolderMatchesSharedList() {
        let home = "/Users/tester"
        #expect(
            ProtectedFolder.allCases.map { $0.path(home: home) }
                == TCCProtectedLocations.protectedFolderPaths(home: home))
    }
}

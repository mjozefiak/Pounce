import Foundation
import Testing

@testable import FilesPlugin

@Suite("TCC-protected locations")
struct TCCProtectedLocationsTests {
    @Test func protectedFoldersAndEverythingBelowThem() {
        let home = "/Users/tester"
        for place in [
            "Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/Containers",
            "Library/Group Containers",
        ] {
            let path = home + "/" + place
            #expect(TCCProtectedLocations.requiresFullDiskAccess(path, home: home), "\(place)")
            #expect(TCCProtectedLocations.requiresFullDiskAccess(path + "/a/b", home: home), "\(place)/a/b")
        }
        #expect(TCCProtectedLocations.requiresFullDiskAccess("/Volumes/USB", home: home))
        #expect(TCCProtectedLocations.requiresFullDiskAccess("/Volumes/Macintosh HD/Users", home: home))
    }

    @Test func otherPlacesAreNotProtected() {
        let home = "/Users/tester"
        for path in [
            "/", "/Volumes", home, home + "/Projects/.ai", home + "/Library", home + "/Library/Mail",
            home + "/DesktopNotes", "/Applications", "/opt/homebrew",
        ] {
            #expect(!TCCProtectedLocations.requiresFullDiskAccess(path, home: home), "\(path)")
        }
    }

    @Test func resolvesExistingPathsAndLinks() throws {
        let directory = try TemporaryDirectory().make(["home/Projects/app/", "home/notes.txt"])
        let home = directory.sub("home")
        let real = try #require(TCCProtectedLocations.realPath(home))
        try FileManager.default.createSymbolicLink(atPath: directory.sub("home/p"), withDestinationPath: "Projects")
        #expect(
            TCCProtectedLocations.resolve(home + "/p/app", home: home, fullDiskAccess: false)
                == .resolved(real + "/Projects/app"))
        #expect(
            TCCProtectedLocations.resolve(home + "/nothing/here", home: home, fullDiskAccess: false) == .missing)
    }

    @Test func linkIntoAProtectedFolderStopsBeforeReadingInside() throws {
        let directory = try TemporaryDirectory().make(["home/Documents/secret/"])
        let home = directory.sub("home")
        let real = try #require(TCCProtectedLocations.realPath(home))
        // An absolute link target, as written by the user (it may go through `/var` → `/private/var`).
        try FileManager.default.createSymbolicLink(
            atPath: directory.sub("home/docs"), withDestinationPath: directory.sub("home/Documents/secret"))
        #expect(
            TCCProtectedLocations.resolve(home + "/docs", home: home, fullDiskAccess: false)
                == .protected(real + "/Documents"))
        #expect(
            TCCProtectedLocations.resolve(real + "/Documents/secret", home: home, fullDiskAccess: false)
                == .protected(real + "/Documents"))
        #expect(
            TCCProtectedLocations.resolve(home + "/docs", home: home, fullDiskAccess: true)
                == .resolved(real + "/Documents/secret"))
    }

    @Test func linkLoopsCountAsMissing() throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.createSymbolicLink(atPath: directory.sub("a"), withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(atPath: directory.sub("b"), withDestinationPath: "a")
        #expect(
            TCCProtectedLocations.resolve(directory.sub("a"), home: directory.path, fullDiskAccess: false) == .missing)
    }

    @Test func otherSpellingsOfAProtectedFolderAreProtected() {
        let home = "/Users/tester"
        for path in [
            "/Users/tester/documents", "/Users/tester/DESKTOP/x", "/users/TESTER/Downloads",
            "/volumes/USB", "/System/Volumes/Data/Users/tester/Documents/a",
            "/system/volumes/data/Volumes/USB",
        ] {
            #expect(TCCProtectedLocations.requiresFullDiskAccess(path, home: home), "\(path)")
        }
        // A home folder name typed in another Unicode normalisation (NFD) is the same folder.
        let accented = "/Users/z\u{00F3}sia"
        #expect(TCCProtectedLocations.requiresFullDiskAccess("/Users/zo\u{0301}sia/Documents", home: accented))
        #expect(!TCCProtectedLocations.requiresFullDiskAccess("/System/Volumes/Data/Users/tester/Projects", home: home))
    }

    @Test func caseVariantOnDiskStopsAtTheFolder() throws {
        let directory = try TemporaryDirectory().make(["home/Documents/secret/"])
        let home = directory.sub("home")
        let real = try #require(TCCProtectedLocations.realPath(home))
        // The temporary volume is case-insensitive like the boot volume, so `documents` is `Documents`.
        let result = TCCProtectedLocations.resolve(home + "/documents/secret", home: home, fullDiskAccess: false)
        #expect(result == .protected(real + "/documents"))
    }

    @Test func relativeLinkWithDotDotIntoAProtectedFolderIsProtected() throws {
        let directory = try TemporaryDirectory().make(["home/Projects/", "home/Documents/x/"])
        let home = directory.sub("home")
        let real = try #require(TCCProtectedLocations.realPath(home))
        try FileManager.default.createSymbolicLink(
            atPath: directory.sub("home/Projects/docs"), withDestinationPath: "../Documents/x")
        #expect(
            TCCProtectedLocations.resolve(home + "/Projects/docs", home: home, fullDiskAccess: false)
                == .protected(real + "/Documents"))
    }

    @Test func homeReachedThroughALinkKeepsItsProtection() throws {
        let directory = try TemporaryDirectory().make(["realhome/Documents/x/"])
        try FileManager.default.createSymbolicLink(atPath: directory.sub("home"), withDestinationPath: "realhome")
        let home = directory.sub("home")
        let realHome = try #require(TCCProtectedLocations.realPath(directory.sub("realhome")))
        #expect(
            TCCProtectedLocations.resolve(home + "/Documents/x", home: home, fullDiskAccess: false)
                == .protected(realHome + "/Documents"))
    }
}

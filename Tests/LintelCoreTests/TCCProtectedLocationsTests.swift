import Foundation
import Testing

@testable import LintelCore

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
}

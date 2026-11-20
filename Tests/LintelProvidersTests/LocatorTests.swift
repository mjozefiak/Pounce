import Foundation
import Testing

@testable import LintelProviders

@Suite struct LocatorTests {
    private func makeHome() throws -> (TempDir, URL) {
        let temp = try TempDir()
        let home = temp.url.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: home.appending(path: ".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appending(path: ".local/share/claude/versions"), withIntermediateDirectories: true)
        return (temp, home)
    }

    private func write(_ url: URL, mode: Int = 0o755) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func locator(home: URL) -> ProviderLocator {
        ProviderLocator(
            homeDirectory: home, searchDirectories: [home.appending(path: ".local/bin")], allowedRoots: [home])
    }

    @Test func findsAFileAndFollowsASymlinkToAValidTarget() throws {
        let (temp, home) = try makeHome()
        defer { temp.remove() }
        let target = home.appending(path: ".local/share/claude/versions/2.1.328")
        try write(target)
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".local/bin/claude"), withDestinationURL: target)
        let found = locator(home: home).locate(.claudeCode, manualPath: nil)
        #expect(found?.standardizedFileURL.path == target.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test func aFileOthersCanWriteIsRejected() throws {
        let (temp, home) = try makeHome()
        defer { temp.remove() }
        try write(home.appending(path: ".local/bin/claude"), mode: 0o775)
        #expect(locator(home: home).locate(.claudeCode, manualPath: nil) == nil)
        try write(home.appending(path: ".local/bin/claude"), mode: 0o757)
        #expect(locator(home: home).locate(.claudeCode, manualPath: nil) == nil)
    }

    @Test func aSymlinkOutsideTheAllowedRootsIsRejected() throws {
        let (temp, home) = try makeHome()
        defer { temp.remove() }
        let outside = temp.url.appending(path: "elsewhere")
        try write(outside)
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".local/bin/claude"), withDestinationURL: outside)
        #expect(locator(home: home).locate(.claudeCode, manualPath: nil) == nil)
    }

    @Test func missingNonExecutableAndDirectoryAreRejected() throws {
        let (temp, home) = try makeHome()
        defer { temp.remove() }
        #expect(locator(home: home).locate(.claudeCode, manualPath: nil) == nil)
        try write(home.appending(path: ".local/bin/claude"), mode: 0o644)
        #expect(locator(home: home).locate(.claudeCode, manualPath: nil) == nil)
        try FileManager.default.removeItem(at: home.appending(path: ".local/bin/claude"))
        try FileManager.default.createDirectory(
            at: home.appending(path: ".local/bin/claude"), withIntermediateDirectories: true)
        #expect(locator(home: home).locate(.claudeCode, manualPath: nil) == nil)
    }

    @Test func aFileOwnedByAnotherUserIsRejected() throws {
        let (temp, home) = try makeHome()
        defer { temp.remove() }
        try write(home.appending(path: ".local/bin/claude"))
        let strangerOnly = ProviderLocator(
            homeDirectory: home, searchDirectories: [home.appending(path: ".local/bin")], allowedRoots: [home],
            userID: getuid() &+ 1)
        #expect(strangerOnly.locate(.claudeCode, manualPath: nil) == nil)
    }

    @Test func aManualPathIsValidatedAsAFile() throws {
        let (temp, home) = try makeHome()
        defer { temp.remove() }
        let elsewhere = temp.url.appending(path: "chosen")
        try write(elsewhere)
        #expect(locator(home: home).locate(.claudeCode, manualPath: elsewhere.path) != nil)
        try write(elsewhere, mode: 0o777)
        #expect(locator(home: home).locate(.claudeCode, manualPath: elsewhere.path) == nil)
        #expect(locator(home: home).locate(.claudeCode, manualPath: temp.url.appending(path: "nope").path) == nil)
    }

    @Test func theDefaultListIsFixed() {
        let home = URL(filePath: "/Users/someone")
        let paths = ProviderLocator(homeDirectory: home).searchDirectories.map(\.path)
        #expect(paths == ["/Users/someone/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }
}

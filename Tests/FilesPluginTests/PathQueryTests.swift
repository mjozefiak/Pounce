import Testing

@testable import FilesPlugin

@Suite("Path query")
struct PathQueryTests {
    let home = "/Users/tester"

    @Test func reportedPathListsTheFolderItself() throws {
        let raw =
            "/Users/tester/Projects/Stage24/ng-stage24/.ai/tmp/sg-auto-create-pr-loop/"
            + "sd-1415-event-creator-qa-fixes-20261027-125110/.ai/runs/2026-10-27-sd-1415-event-creator-qa-fixes/"
        let query = try #require(PathQuery.parse(raw, home: home))
        #expect(query.folder == String(raw.dropLast()))
        #expect(query.filter.isEmpty)
        #expect(!query.usesTilde)
    }

    @Test func textAfterTheLastSlashFilters() throws {
        let query = try #require(PathQuery.parse("~/Projects/ng-St", home: home))
        #expect(query.folder == "/Users/tester/Projects")
        #expect(query.filter == "ng-St")
        #expect(query.normalizedFilter == "ng-st")
        #expect(query.usesTilde)
    }

    @Test func tildeAloneAndRoot() throws {
        #expect(PathQuery.parse("~", home: home) == PathQuery(folder: home, filter: "", usesTilde: true))
        #expect(PathQuery.parse("~/", home: home)?.folder == home)
        #expect(PathQuery.parse("/", home: home) == PathQuery(folder: "/", filter: "", usesTilde: false))
        #expect(PathQuery.parse("/App", home: home) == PathQuery(folder: "/", filter: "App", usesTilde: false))
    }

    @Test func otherQueriesAreNotPaths() {
        #expect(PathQuery.parse("budget", home: home) == nil)
        #expect(PathQuery.parse("stage24/runs", home: home) == nil)
        #expect(PathQuery.parse("~tester", home: home) == nil)
        #expect(PathQuery.parse("", home: home) == nil)
        #expect(!PathQuery.isPath("Safari"))
        #expect(PathQuery.isPath("  /tmp/  "))
    }

    @Test func surroundingSpacesAreIgnoredButInnerSpacesKept() throws {
        let query = try #require(PathQuery.parse("  ~/My Folder/Sub Dir/no  ", home: home))
        #expect(query.folder == "/Users/tester/My Folder/Sub Dir")
        #expect(query.filter == "no")
    }

    @Test func terminalQuotingIsRemoved() throws {
        #expect(PathQuery.parse("'/tmp/a b/'", home: home)?.folder == "/tmp/a b")
        #expect(PathQuery.parse("\"~/x/\"", home: home)?.folder == "/Users/tester/x")
        #expect(PathQuery.parse("/tmp/My\\ Folder/", home: home)?.folder == "/tmp/My Folder")
    }

    @Test func dotsAreStandardisedAndHiddenFilterDetected() throws {
        let query = try #require(PathQuery.parse("~/a/../b/./.gi", home: home))
        #expect(query.folder == "/Users/tester/b")
        #expect(query.wantsHidden)
    }
}

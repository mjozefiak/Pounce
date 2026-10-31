import Testing

@testable import FilesPlugin

/// Spec step 3.0: root selection with and without Full Disk Access.
@Suite struct RootPlannerTests {
    let home = "/Users/demo"
    var rules: IgnoreRules { IgnoreRules.make(home: home, userExclusions: [], includesHidden: false) }

    func plan(
        roots: [String]? = nil, fda: Bool, added: Set<ProtectedFolder> = [], iCloud: Bool = true
    ) -> IndexPlan {
        RootPlanner.plan(
            configuredRoots: roots, home: home, fullDiskAccess: fda, addedProtected: added,
            includesICloudDrive: iCloud, rules: rules)
    }

    @Test func withFullDiskAccessEverythingIsIndexedAndICloudIsItsOwnRoot() {
        let plan = plan(fda: true)
        #expect(plan.roots == ["/Users/demo", "/Applications", "/Users/demo/Library/Mobile Documents"])
        #expect(plan.skippedProtectedPaths.isEmpty)
        #expect(plan.indexedProtected == Set(ProtectedFolder.allCases))
        #expect(!plan.rules.excludes(name: "Desktop", path: "/Users/demo/Desktop"))
    }

    @Test func withFullDiskAccessICloudCanBeTurnedOff() {
        let plan = plan(fda: true, iCloud: false)
        #expect(plan.roots == ["/Users/demo", "/Applications"])
        #expect(!plan.indexedProtected.contains(.iCloudDrive))
    }

    @Test func withoutFullDiskAccessProtectedFoldersAreSkipped() {
        let plan = plan(fda: false)
        #expect(plan.roots == ["/Users/demo", "/Applications"])
        #expect(
            plan.skippedProtectedPaths == ["/Users/demo/Desktop", "/Users/demo/Documents", "/Users/demo/Downloads"])
        #expect(plan.indexedProtected.isEmpty)
        #expect(plan.rules.excludes(name: "Desktop", path: "/Users/demo/Desktop"))
        #expect(plan.rules.excludes(name: "Downloads", path: "/Users/demo/Downloads"))
        #expect(!plan.rules.excludes(name: "Pictures", path: "/Users/demo/Pictures"))
    }

    @Test func withoutFullDiskAccessAddedFoldersAreIndexedOneByOne() {
        let plan = plan(fda: false, added: [.documents, .iCloudDrive])
        #expect(plan.roots == ["/Users/demo", "/Applications", "/Users/demo/Library/Mobile Documents"])
        #expect(plan.skippedProtectedPaths == ["/Users/demo/Desktop", "/Users/demo/Downloads"])
        #expect(plan.indexedProtected == [.documents, .iCloudDrive])
    }

    @Test func addedFolderOutsideEveryRootBecomesARoot() {
        let plan = plan(roots: ["/Applications"], fda: false, added: [.desktop])
        #expect(plan.roots == ["/Applications", "/Users/demo/Desktop"])
        #expect(plan.skippedProtectedPaths.isEmpty)
    }

    @Test func configuredRootsAreExpandedFilteredAndDeduplicated() {
        let plan = plan(
            roots: [
                "~/Projects", "~/Projects/App", "/Volumes/USB", "/System/Volumes/Data/Users", "relative", "/tmp/x/",
            ],
            fda: true, iCloud: false)
        #expect(plan.roots == ["/Users/demo/Projects", "/tmp/x"])
    }

    @Test func fingerprintFollowsThePlan() {
        #expect(plan(fda: true).fingerprint != plan(fda: false).fingerprint)
        #expect(plan(fda: false).fingerprint == plan(fda: false).fingerprint)
    }

    @Test func pathText() {
        #expect(PathText.parent("/a/b/c") == "/a/b")
        #expect(PathText.parent("/a") == "/")
        #expect(PathText.name("/a/b/c.txt") == "c.txt")
        #expect(PathText.contains("/a", "/a/b"))
        #expect(!PathText.contains("/a", "/ab"))
        #expect(PathText.abbreviate("/Users/demo/x", home: home) == "~/x")
        #expect(PathText.abbreviate("/Users/demox", home: home) == "/Users/demox")
    }
}

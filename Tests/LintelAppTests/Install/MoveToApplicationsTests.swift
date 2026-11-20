import AppKit
import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// Spec `2026-11-19-updates-and-open-source-hygiene`, step 4.2: the location decision table.
@MainActor
@Suite struct ApplicationLocationTests {
    static let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    static let allowed = ApplicationLocation.allowedFolders(home: home)

    /// Resolves links by prefix, like a disk where these paths are symbolic links.
    static func resolver(_ links: [String: String]) -> (URL) -> URL {
        { url in
            let path = url.path
            for (link, target) in links where path == link || path.hasPrefix(link + "/") {
                return URL(filePath: target + path.dropFirst(link.count))
            }
            return url
        }
    }

    static func classify(_ path: String, links: [String: String] = [:]) -> ApplicationLocation {
        ApplicationLocation.classify(
            bundleURL: URL(filePath: path, directoryHint: .isDirectory), allowedFolders: allowed,
            resolveSymlinks: resolver(links))
    }

    @Test(arguments: [
        ("/Applications/Lintel.app", ApplicationLocation.applications),
        ("/Applications/Utilities/Lintel.app", .applications),
        ("/Users/tester/Applications/Lintel.app", .applications),
        ("/Volumes/Lintel/Lintel.app", .mountedVolume),
        (
            "/private/var/folders/x1/abc123/T/AppTranslocation/9F1C2B7E-1D2A-4C55-8E0B-3A4F5D6E7F80/d/Lintel.app",
            .translocated
        ),
        ("/Users/tester/Downloads/Lintel.app", .elsewhere),
        ("/Users/tester/Desktop/Lintel.app", .elsewhere),
        ("/ApplicationsOld/Lintel.app", .elsewhere),
        ("/Applications", .elsewhere),
    ])
    func decisionTable(path: String, expected: ApplicationLocation) {
        #expect(Self.classify(path) == expected, "\(path)")
    }

    @Test func aSymlinkedApplicationsFolderCountsAsApplications() {
        // ~/Applications is a link to a folder on another disk; the bundle path arrives resolved.
        let links = ["/Users/tester/Applications": "/Volumes/Apps"]
        #expect(Self.classify("/Volumes/Apps/Lintel.app", links: links) == .applications)
        // /Applications reported through the firmlinked data volume.
        let data = ["/Applications": "/System/Volumes/Data/Applications"]
        #expect(Self.classify("/System/Volumes/Data/Applications/Lintel.app", links: data) == .applications)
        // The boot volume's link to `/` under /Volumes is Applications, not a mounted image.
        let boot = ["/Volumes/Macintosh HD": "/"]
        #expect(Self.classify("/Volumes/Macintosh HD/Applications/Lintel.app", links: boot) == .applications)
        #expect(Self.classify("/Volumes/Macintosh HD/Users/tester/Downloads/Lintel.app", links: boot) == .elsewhere)
    }

    @Test func aRealSymlinkInATemporaryDirectoryIsResolved() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "lintel-location-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "RealApps", directoryHint: .isDirectory)
        let bundle = real.appending(path: "Lintel.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let link = root.appending(path: "Applications")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let viaLink = link.appending(path: "Lintel.app", directoryHint: .isDirectory)
        #expect(ApplicationLocation.classify(bundleURL: bundle, allowedFolders: [link]) == .applications)
        #expect(ApplicationLocation.classify(bundleURL: viaLink, allowedFolders: [real]) == .applications)
        #expect(
            ApplicationLocation.classify(bundleURL: bundle, allowedFolders: [root.appending(path: "Other")])
                == .elsewhere)
    }

    @Test func onlyApplicationsSkipsTheOffer() {
        #expect(!ApplicationLocation.applications.offersMove)
        #expect(ApplicationLocation.translocated.offersMove)
        #expect(ApplicationLocation.mountedVolume.offersMove)
        #expect(ApplicationLocation.elsewhere.offersMove)
        #expect(ApplicationLocation.destination.path == "/Applications/Lintel.app")
    }
}

/// A disk in memory: each path holds a bundle with an identity and a quarantine flag. `ditto` keeps the flag, like
/// the real one keeps extended attributes.
@MainActor
final class FakeInstallDisk: InstallFileManaging, RunningAppListing, QuarantineRemoving, AppRelaunching,
    BundleVersionReading
{
    struct Bundle: Equatable {
        var identity: String
        var quarantined: Bool
        var build: String?

        init(identity: String, quarantined: Bool, build: String? = nil) {
            self.identity = identity
            self.quarantined = quarantined
            self.build = build
        }
    }

    enum Failing { case copy, trash, move, open, quarantine }

    static let trash = "/Users/tester/.Trash/Lintel.app"
    var items: [String: Bundle] = [:]
    var running: Set<String> = []
    var failing: Set<Failing> = []
    var log: [String] = []
    var opened: [String] = []
    var openedAsNewInstance: [Bool] = []
    var quitCalls = 0

    struct Failure: Error {}

    func itemExists(at url: URL) -> Bool { items[url.path] != nil }

    func copyBundle(from source: URL, to destination: URL) throws {
        log.append("copy \(source.path) -> \(destination.path)")
        if failing.contains(.copy) {
            // A partial copy may be left behind.
            items[destination.path] = Bundle(identity: "partial", quarantined: true)
            throw Failure()
        }
        guard let bundle = items[source.path] else { throw Failure() }
        items[destination.path] = bundle
    }

    func trashItem(at url: URL) throws -> URL {
        log.append("trash \(url.path)")
        if failing.contains(.trash) { throw Failure() }
        guard let bundle = items.removeValue(forKey: url.path) else { throw Failure() }
        items[Self.trash] = bundle
        return URL(filePath: Self.trash)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        log.append("move \(source.path) -> \(destination.path)")
        if failing.contains(.move), source.path != Self.trash { throw Failure() }
        guard items[destination.path] == nil, let bundle = items.removeValue(forKey: source.path) else {
            throw Failure()
        }
        items[destination.path] = bundle
    }

    func removeStagingItem(at url: URL) throws {
        log.append("remove \(url.path)")
        items[url.path] = nil
    }

    func isRunning(bundleAt url: URL) -> Bool { running.contains(url.path) }

    func removeQuarantine(at url: URL) throws {
        log.append("unquarantine \(url.path)")
        if failing.contains(.quarantine) { throw Failure() }
        items[url.path]?.quarantined = false
    }

    func open(_ url: URL, newInstance: Bool) async throws {
        if failing.contains(.open) { throw Failure() }
        opened.append(url.path)
        openedAsNewInstance.append(newInstance)
    }

    func buildNumber(ofBundleAt url: URL) -> String? { items[url.path]?.build }

    func quit() { quitCalls += 1 }
}

/// Spec step 4.2: the Move flow table.
@MainActor
@Suite struct MoveToApplicationsFlowTests {
    static let source = URL(filePath: "/Volumes/Lintel/Lintel.app", directoryHint: .isDirectory)
    static let destination = "/Applications/Lintel.app"
    static let staging = "/Applications/.Lintel-moving-test.app"

    static func makeDisk(existing: Bool, newBuild: String? = "200", oldBuild: String? = "100") -> FakeInstallDisk {
        let disk = FakeInstallDisk()
        disk.items[source.path] = .init(identity: "new", quarantined: true, build: newBuild)
        if existing { disk.items[destination] = .init(identity: "old", quarantined: false, build: oldBuild) }
        return disk
    }

    static func mover(_ disk: FakeInstallDisk) -> MoveToApplications {
        var mover = MoveToApplications(
            files: disk, processes: disk, quarantine: disk, relauncher: disk, versions: disk)
        mover.stagingName = { ".Lintel-moving-test.app" }
        return mover
    }

    @Test func noExistingCopy() async throws {
        let disk = Self.makeDisk(existing: false)
        try await Self.mover(disk).run(from: Self.source)
        #expect(disk.items[Self.destination]?.identity == "new")
        #expect(disk.items[Self.staging] == nil)
        #expect(disk.items[FakeInstallDisk.trash] == nil)
        #expect(!disk.log.contains { $0.hasPrefix("trash") })
        #expect(disk.items[Self.source.path] != nil, "the running copy is copied, not moved")
        #expect(disk.opened == [Self.destination])
        #expect(disk.quitCalls == 1)
    }

    @Test func anExistingCopyThatIsNotRunningGoesToTheTrash() async throws {
        let disk = Self.makeDisk(existing: true)
        try await Self.mover(disk).run(from: Self.source)
        #expect(disk.items[FakeInstallDisk.trash]?.identity == "old")
        #expect(disk.items[Self.destination]?.identity == "new")
        #expect(!disk.log.contains("remove \(Self.destination)"), "the old copy is never deleted")
        #expect(disk.quitCalls == 1)
    }

    @Test func anExistingCopyThatIsRunningRefusesAndChangesNothing() async {
        let disk = Self.makeDisk(existing: true)
        disk.running = [Self.destination]
        let before = disk.items
        await #expect(throws: MoveToApplications.Failure.destinationRunning) {
            try await Self.mover(disk).run(from: Self.source)
        }
        #expect(disk.items == before)
        #expect(disk.log.isEmpty)
        #expect(disk.opened.isEmpty)
        #expect(disk.quitCalls == 0)
    }

    @Test func aNewerInstalledCopyIsKeptAndNothingIsReplaced() async {
        let disk = Self.makeDisk(existing: true, newBuild: "100", oldBuild: "200")
        let before = disk.items
        await #expect(throws: MoveToApplications.Failure.installedCopyIsNewer) {
            try await Self.mover(disk).run(from: Self.source)
        }
        #expect(disk.items == before)
        #expect(disk.log.isEmpty)
        #expect(disk.quitCalls == 0)
    }

    @Test(arguments: [
        ("100", "100", false), ("200", "100", true), ("100", "200", false), ("9", "10", false), ("10", "9", true),
        ("1.2.10", "1.2.9", true), ("1.2", "1.2.0", false), ("1.2.1", "1.2", true), ("abc", "1", false),
        ("1", "abc", false), ("", "1", false), ("1..2", "1", false),
    ])
    func buildNumberComparison(installed: String, running: String, expectedNewer: Bool) async {
        let disk = Self.makeDisk(existing: true, newBuild: running, oldBuild: installed)
        #expect(Self.mover(disk).installedCopyIsNewer(than: Self.source) == expectedNewer)
    }

    @Test func anUnreadableVersionNeverBlocksTheMove() async throws {
        let disk = Self.makeDisk(existing: true, newBuild: "200", oldBuild: nil)
        #expect(!Self.mover(disk).installedCopyIsNewer(than: Self.source))
        try await Self.mover(disk).run(from: Self.source)
        #expect(disk.items[Self.destination]?.identity == "new")
    }

    @Test func openingTheInstalledCopyChangesNothingAndQuits() async throws {
        let disk = Self.makeDisk(existing: true, newBuild: "100", oldBuild: "200")
        let before = disk.items
        try await Self.mover(disk).openInstalledCopy()
        #expect(disk.items == before)
        #expect(disk.log.isEmpty)
        #expect(disk.opened == [Self.destination])
        #expect(disk.openedAsNewInstance == [true], "this copy has the same bundle identifier, so it starts a new one")
        #expect(disk.quitCalls == 1)
        // A running installed copy is activated, not started twice.
        let running = Self.makeDisk(existing: true, newBuild: "100", oldBuild: "200")
        running.running = [Self.destination]
        try await Self.mover(running).openInstalledCopy()
        #expect(running.openedAsNewInstance == [false])
    }

    @Test func aFailedOpenOfTheInstalledCopyKeepsThisCopyRunning() async {
        let disk = Self.makeDisk(existing: true, newBuild: "100", oldBuild: "200")
        disk.failing = [.open]
        await #expect(throws: MoveToApplications.Failure.openFailed) {
            try await Self.mover(disk).openInstalledCopy()
        }
        #expect(disk.quitCalls == 0)
    }

    @Test func theQuarantineAttributeIsRemovedFromTheCopy() async throws {
        let disk = Self.makeDisk(existing: false)
        try await Self.mover(disk).run(from: Self.source)
        #expect(disk.items[Self.destination]?.quarantined == false)
        #expect(disk.items[Self.source.path]?.quarantined == true, "the original keeps its attribute")
        #expect(disk.log.contains("unquarantine \(Self.staging)"))
        // Removed before the copy is opened.
        let unquarantine = disk.log.firstIndex(of: "unquarantine \(Self.staging)")
        let rename = disk.log.firstIndex(of: "move \(Self.staging) -> \(Self.destination)")
        #expect((unquarantine ?? .max) < (rename ?? .min))
    }

    @Test func aCopyFailureLeavesTheOldCopyInPlace() async {
        let disk = Self.makeDisk(existing: true)
        disk.failing = [.copy]
        await #expect(throws: MoveToApplications.Failure.copyFailed) {
            try await Self.mover(disk).run(from: Self.source)
        }
        #expect(disk.items[Self.destination]?.identity == "old")
        #expect(disk.items[FakeInstallDisk.trash] == nil)
        #expect(disk.items[Self.staging] == nil, "the partial copy is removed")
        #expect(disk.items[Self.source.path] != nil)
        #expect(disk.opened.isEmpty)
        #expect(disk.quitCalls == 0)
    }

    @Test func aTrashFailureChangesNothing() async {
        let disk = Self.makeDisk(existing: true)
        disk.failing = [.trash]
        await #expect(throws: MoveToApplications.Failure.trashFailed) {
            try await Self.mover(disk).run(from: Self.source)
        }
        #expect(disk.items[Self.destination]?.identity == "old")
        #expect(disk.items[Self.staging] == nil)
        #expect(disk.quitCalls == 0)
    }

    @Test func aFailedRenamePutsTheOldCopyBack() async {
        let disk = Self.makeDisk(existing: true)
        disk.failing = [.move]
        await #expect(throws: MoveToApplications.Failure.installFailed(restored: true)) {
            try await Self.mover(disk).run(from: Self.source)
        }
        #expect(disk.items[Self.destination]?.identity == "old")
        #expect(disk.items[FakeInstallDisk.trash] == nil)
        #expect(disk.items[Self.staging] == nil)
        #expect(disk.quitCalls == 0)
    }

    @Test func aFailedOpenKeepsThisCopyRunning() async {
        let disk = Self.makeDisk(existing: false)
        disk.failing = [.open]
        await #expect(throws: MoveToApplications.Failure.openFailed) {
            try await Self.mover(disk).run(from: Self.source)
        }
        #expect(disk.items[Self.destination]?.identity == "new")
        #expect(disk.quitCalls == 0)
    }

    @Test func aQuarantineFailureDoesNotStopTheMove() async throws {
        let disk = Self.makeDisk(existing: false)
        disk.failing = [.quarantine]
        try await Self.mover(disk).run(from: Self.source)
        #expect(disk.items[Self.destination]?.identity == "new")
        #expect(disk.quitCalls == 1)
    }
}

/// The alert's decision, the `app.install.moveDeclined` key and the QA argument.
@MainActor
@Suite struct MoveToApplicationsPromptTests {
    static let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    static func prompt(
        _ settings: InMemorySettingsStore, disk: FakeInstallDisk, answer: MoveToApplicationsPrompt.Answer,
        asked: @escaping (MoveToApplicationsPrompt.Variant) -> Void = { _ in },
        reported: @escaping (MoveToApplications.Failure) -> Void = { _ in }
    ) -> MoveToApplicationsPrompt {
        var prompt = MoveToApplicationsPrompt(
            settings: settings, mover: MoveToApplicationsFlowTests.mover(disk))
        prompt.ask = {
            asked($0)
            return answer
        }
        prompt.report = reported
        return prompt
    }

    @Test func theKeyIsProtectedAndDefaultsToFalse() {
        #expect(SettingsKeys.moveDeclined == "app.install.moveDeclined")
        let settings = InMemorySettingsStore()
        #expect(!MoveToApplicationsPrompt.isDeclined(settings))
        #expect(settings.value(forKey: SettingsKeys.moveDeclined) == nil)
    }

    @Test func dontAskAgainIsStoredAndStopsTheNextOffer() async {
        let settings = InMemorySettingsStore()
        let disk = MoveToApplicationsFlowTests.makeDisk(existing: false)
        let outcome = await Self.prompt(settings, disk: disk, answer: .init(move: false, dontAskAgain: true))
            .offerIfNeeded(bundleURL: MoveToApplicationsFlowTests.source, home: Self.home)
        #expect(outcome == .declined)
        #expect(settings.value(forKey: SettingsKeys.moveDeclined) == .bool(true))
        #expect(MoveToApplicationsPrompt.isDeclined(settings))
        var asked = false
        let next = await Self.prompt(
            settings, disk: disk, answer: .init(move: true, dontAskAgain: false), asked: { _ in asked = true }
        ).offerIfNeeded(bundleURL: MoveToApplicationsFlowTests.source, home: Self.home)
        #expect(next == .notOffered)
        #expect(!asked)
        #expect(disk.log.isEmpty)
    }

    @Test func dontMoveWithoutDontAskAgainAsksAgainNextLaunch() async {
        let settings = InMemorySettingsStore()
        let disk = MoveToApplicationsFlowTests.makeDisk(existing: false)
        let outcome = await Self.prompt(settings, disk: disk, answer: .init(move: false, dontAskAgain: false))
            .offerIfNeeded(bundleURL: MoveToApplicationsFlowTests.source, home: Self.home)
        #expect(outcome == .declined)
        #expect(settings.value(forKey: SettingsKeys.moveDeclined) == nil)
        #expect(
            MoveToApplicationsPrompt.shouldOffer(
                bundleURL: MoveToApplicationsFlowTests.source, home: Self.home, settings: settings))
    }

    @Test func anAppInApplicationsOrUnbundledIsNeverAsked() async {
        let settings = InMemorySettingsStore()
        let disk = MoveToApplicationsFlowTests.makeDisk(existing: false)
        var asked = false
        let prompt = Self.prompt(settings, disk: disk, answer: .init(move: true, dontAskAgain: false)) { _ in
            asked = true
        }
        let inApplications = await prompt.offerIfNeeded(
            bundleURL: URL(filePath: "/Applications/Lintel.app"), home: Self.home)
        // `swift run`: the main bundle is the build folder, not an app bundle.
        let unbundled = await prompt.offerIfNeeded(
            bundleURL: URL(filePath: "/Users/tester/src/Lintel/.build/debug"), home: Self.home)
        #expect(inApplications == .notOffered)
        #expect(unbundled == .notOffered)
        #expect(!asked)
    }

    @Test func moveRunsTheFlowAndAFailureIsReported() async {
        let settings = InMemorySettingsStore()
        let disk = MoveToApplicationsFlowTests.makeDisk(existing: false)
        let moved = await Self.prompt(settings, disk: disk, answer: .init(move: true, dontAskAgain: false))
            .offerIfNeeded(bundleURL: MoveToApplicationsFlowTests.source, home: Self.home)
        #expect(moved == .moved)
        #expect(disk.quitCalls == 1)

        let busy = MoveToApplicationsFlowTests.makeDisk(existing: true)
        busy.running = [MoveToApplicationsFlowTests.destination]
        var reported: [MoveToApplications.Failure] = []
        let refused = await Self.prompt(
            settings, disk: busy, answer: .init(move: true, dontAskAgain: false), reported: { reported.append($0) }
        ).offerIfNeeded(bundleURL: MoveToApplicationsFlowTests.source, home: Self.home)
        #expect(refused == .failed(.destinationRunning))
        #expect(reported == [.destinationRunning])
        #expect(!MoveToApplicationsPrompt.failureMessage(.destinationRunning).isEmpty)
    }

    @Test func aNewerInstalledCopyGetsItsOwnAlertAndOpensInstead() async {
        let settings = InMemorySettingsStore()
        let disk = MoveToApplicationsFlowTests.makeDisk(existing: true, newBuild: "100", oldBuild: "200")
        let before = disk.items
        var variants: [MoveToApplicationsPrompt.Variant] = []
        let outcome = await Self.prompt(
            settings, disk: disk, answer: .init(move: true, dontAskAgain: false), asked: { variants.append($0) }
        ).offerIfNeeded(bundleURL: MoveToApplicationsFlowTests.source, home: Self.home)
        #expect(variants == [.newerInstalled])
        #expect(outcome == .openedInstalledCopy)
        #expect(!outcome.continuesLaunch)
        #expect(disk.items == before, "nothing is replaced")
        #expect(disk.opened == [MoveToApplicationsFlowTests.destination])
        #expect(disk.quitCalls == 1)
        // Declining keeps everything and keeps running.
        let declined = await Self.prompt(settings, disk: disk, answer: .init(move: false, dontAskAgain: false))
            .offerIfNeeded(bundleURL: MoveToApplicationsFlowTests.source, home: Self.home)
        #expect(declined == .declined)
        #expect(declined.continuesLaunch)
        #expect(disk.items == before)
    }

    @Test func theOutcomesThatQuitDoNotContinueTheLaunch() {
        #expect(!MoveToApplicationsPrompt.Outcome.moved.continuesLaunch)
        #expect(MoveToApplicationsPrompt.Outcome.notOffered.continuesLaunch)
        #expect(MoveToApplicationsPrompt.Outcome.failed(.copyFailed).continuesLaunch)
    }

    @Test func theNewerInstalledAlertHasItsButtonsAndAccessibilityLabels() throws {
        let alert = MoveToApplicationsPrompt.makeAlert(.newerInstalled)
        #expect(alert.messageText == "A newer Lintel is already in Applications")
        #expect(alert.buttons.map(\.title) == ["Open Installed Copy", "Don't Move"])
        let suppression = try #require(alert.suppressionButton)
        for control in alert.buttons + [suppression] {
            #expect(!(control.accessibilityLabel() ?? "").isEmpty, "\(control.title) has no accessibility label")
        }
    }

    @Test func aCopyFailureReportsAndLeavesTheOldCopy() async {
        let settings = InMemorySettingsStore()
        let disk = MoveToApplicationsFlowTests.makeDisk(existing: true)
        disk.failing = [.copy]
        var reported: [MoveToApplications.Failure] = []
        let outcome = await Self.prompt(
            settings, disk: disk, answer: .init(move: true, dontAskAgain: false), reported: { reported.append($0) }
        ).offerIfNeeded(bundleURL: MoveToApplicationsFlowTests.source, home: Self.home)
        #expect(outcome == .failed(.copyFailed))
        #expect(reported == [.copyFailed])
        #expect(disk.items[MoveToApplicationsFlowTests.destination]?.identity == "old")
        #expect(disk.quitCalls == 0)
    }

    @Test func theAlertHasItsButtonsAndAccessibilityLabels() throws {
        let alert = MoveToApplicationsPrompt.makeAlert()
        #expect(alert.messageText == "Move Lintel to Applications?")
        #expect(alert.buttons.map(\.title) == ["Move", "Don't Move"])
        let suppression = try #require(alert.suppressionButton)
        #expect(alert.showsSuppressionButton)
        #expect(suppression.title == "Don't ask again")
        for control in alert.buttons + [suppression] {
            let label = control.accessibilityLabel() ?? ""
            #expect(!label.isEmpty, "\(control.title) has no accessibility label")
        }
    }

    #if DEBUG
    @Test func theQAArgumentShowsThePromptInFullQAMode() throws {
        let options = try #require(try QAOptions.parse(["Lintel", "--qa-move-prompt"]))
        #expect(options.showsMovePrompt)
        #expect(options.dataRoot == nil, "the rest of QA isolation still applies")
        #expect(try QAOptions.parse(["--qa"])?.showsMovePrompt == false)
        #expect(try QAOptions.parse(["Lintel"]) == nil)
        let combined = try #require(
            try QAOptions.parse(["--qa-move-prompt", "--qa-setting", "app.install.moveDeclined=true"]))
        #expect(combined.settings[SettingsKeys.moveDeclined] == .bool(true))
    }

    @Test func theQAFakesNeverTouchTheDiskOrQuit() async throws {
        let settings = InMemorySettingsStore()
        let fakes = QAInstallFakes()
        var prompt = MoveToApplicationsPrompt(
            settings: settings,
            mover: MoveToApplications(
                files: fakes, processes: fakes, quarantine: fakes, relauncher: fakes, versions: fakes))
        prompt.ask = { _ in .init(move: true, dontAskAgain: false) }
        let outcome = await prompt.offerIfNeeded(bundleURL: QAInstallFakes.bundleURL, home: Self.home)
        #expect(outcome == .moved, "the fakes report success without copying, trashing or quitting")
    }
    #endif
}

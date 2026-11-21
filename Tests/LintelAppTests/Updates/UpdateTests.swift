import AppKit
import Foundation
import LintelKit
import Testing

@testable import LintelApp

@MainActor
@Suite struct UpdaterStartPolicyTests {
    nonisolated static let home = URL(fileURLWithPath: "/Users/tester")

    nonisolated static func facts(
        debug: Bool = false,
        bundle: String = "/Applications/Lintel.app",
        team: String? = "39G44CM6GF",
        key: String? = "cHVibGljLWtleQ==",
        feed: String? = "https://lintelapp.com/appcast.xml"
    ) -> UpdaterStartPolicy.Facts {
        UpdaterStartPolicy.Facts(
            isDebugBuild: debug, bundleURL: URL(fileURLWithPath: bundle), teamIdentifier: team, publicKey: key,
            feedURL: feed, homeDirectory: home)
    }

    @Test func aSignedReleaseBuildInApplicationsWithAKeyStarts() {
        #expect(UpdaterStartPolicy.decide(Self.facts()) == .start)
        #expect(UpdaterStartPolicy.decide(Self.facts(bundle: "/Users/tester/Applications/Lintel.app")) == .start)
    }

    @Test(arguments: [
        (facts(debug: true), UpdaterStartPolicy.Refusal.debugBuild),
        (facts(bundle: "/Applications/Lintel.app/Contents/MacOS/Lintel"), .notAnAppBundle),
        (facts(bundle: "/Volumes/Lintel/Lintel.app"), .outsideApplications),
        (facts(bundle: "/Users/tester/Downloads/Lintel.app"), .outsideApplications),
        (facts(bundle: "/Applications/Tools/Lintel.app"), .outsideApplications),
        (facts(bundle: "/private/var/folders/x/AppTranslocation/1/d/Lintel.app"), .outsideApplications),
        (facts(bundle: "/Users/other/Applications/Lintel.app"), .outsideApplications),
        (facts(team: nil), .adHocSignature),
        (facts(team: ""), .adHocSignature),
        (facts(key: nil), .noPublicKey),
        (facts(key: "  \n"), .noPublicKey),
        (facts(feed: nil), .noFeed),
        (facts(feed: "http://lintelapp.com/appcast.xml"), .noFeed),
    ])
    func everythingElseIsRefused(facts: UpdaterStartPolicy.Facts, reason: UpdaterStartPolicy.Refusal) {
        #expect(UpdaterStartPolicy.decide(facts) == .refuse(reason))
    }

    /// The order matters for DEBUG builds: they are refused before anything else is looked at.
    @Test func aDebugBuildIsRefusedEvenWhenEverythingElseIsRight() {
        #expect(UpdaterStartPolicy.decide(Self.facts(debug: true)) == .refuse(.debugBuild))
    }
}

@MainActor
@Suite struct UpdateChannelTests {
    @Test func betaIsOfferedOnlyWhenIncluded() {
        #expect(UpdateChannel.allowed(includeBeta: true) == ["beta"])
        #expect(UpdateChannel.allowed(includeBeta: false).isEmpty)
    }

    @Test(arguments: [
        ("0.1.0-beta.1", true), ("1.2.3-beta.12", true), ("0.1.0", false), ("0.0.0", false), ("", false),
    ])
    func preReleaseVersionsAreRecognised(version: String, expected: Bool) {
        #expect(UpdateChannel.isPreRelease(version: version) == expected)
    }

    @Test func aPreReleaseBuildWritesTheSettingOnce() {
        let settings = InMemorySettingsStore()
        #expect(UpdateChannel.includeBeta(settings: settings, runningVersion: "0.1.0-beta.1"))
        #expect(settings.value(forKey: "app.updates.includeBeta") == .bool(true))
    }

    @Test func aStableBuildWritesNothingAndMeansNo() {
        let settings = InMemorySettingsStore()
        #expect(!UpdateChannel.includeBeta(settings: settings, runningVersion: "0.1.0"))
        #expect(settings.value(forKey: "app.updates.includeBeta") == nil)
    }

    @Test func theUsersChoiceIsNeverReplaced() {
        let settings = InMemorySettingsStore()
        settings.setValue(.bool(false), forKey: "app.updates.includeBeta")
        #expect(!UpdateChannel.includeBeta(settings: settings, runningVersion: "0.2.0-beta.1"))
        #expect(settings.value(forKey: "app.updates.includeBeta") == .bool(false))
        settings.setValue(.bool(true), forKey: "app.updates.includeBeta")
        #expect(UpdateChannel.includeBeta(settings: settings, runningVersion: "0.2.0"))
    }
}

@MainActor
@Suite struct UpdateControllerTests {
    final class FakeChecker: UpdateChecking {
        var started = 0
        var checks = 0
        var startError: (any Error)?
        var allowedChannels: Set<String> = []
        var canCheckForUpdates: Bool { started > 0 }
        func start() throws {
            if let startError { throw startError }
            started += 1
        }
        func checkForUpdates() { checks += 1 }
        var onEvent: ((UpdateEvent) -> Void)?
        var shouldPostponeRelaunch: (() -> Bool)?
        var resumed = 0
        var postponed = false
        var hasPostponedRelaunch: Bool { postponed }
        func resumePostponedRelaunch() {
            postponed = false
            resumed += 1
        }
        /// What Sparkle does when an update is ready to install: asks, and holds the relaunch on "yes".
        func readyToRelaunch() {
            postponed = shouldPostponeRelaunch?() ?? false
            if postponed { onEvent?(.relaunchPostponed) }
        }
    }

    struct Boom: Error {}

    func controller(
        _ facts: UpdaterStartPolicy.Facts, settings: InMemorySettingsStore = InMemorySettingsStore(),
        version: String = "0.1.0", made: @escaping (FakeChecker) -> Void = { _ in }, error: (any Error)? = nil
    ) -> UpdateController {
        UpdateController(
            facts: facts, settings: settings, runningVersion: version,
            makeChecker: {
                let checker = FakeChecker()
                checker.startError = error
                made(checker)
                return checker
            })
    }

    @Test func aRefusedPolicyCreatesNoCheckerAndWritesNoSetting() {
        var made = 0
        let settings = InMemorySettingsStore()
        let controller = controller(
            UpdaterStartPolicyTests.facts(key: nil), settings: settings, version: "0.1.0-beta.1",
            made: { _ in made += 1 })
        controller.startIfAllowed()
        #expect(controller.state == .off(.noPublicKey))
        #expect(made == 0)
        #expect(!controller.canCheckForUpdates)
        controller.checkForUpdates()
        #expect(settings.value(forKey: "app.updates.includeBeta") == nil)
    }

    @Test func anAllowedPolicyStartsTheCheckerOnceWithTheChannels() {
        var checkers: [FakeChecker] = []
        let controller = controller(
            UpdaterStartPolicyTests.facts(), version: "0.1.0-beta.1", made: { checkers.append($0) })
        controller.startIfAllowed()
        controller.startIfAllowed()
        #expect(controller.state == .running)
        #expect(checkers.count == 1)
        #expect(checkers.first?.started == 1)
        #expect(checkers.first?.allowedChannels == ["beta"])
        #expect(controller.canCheckForUpdates)
        controller.checkForUpdates()
        #expect(checkers.first?.checks == 1)
    }

    @Test func aStableBuildOffersNoBetaChannel() {
        var checkers: [FakeChecker] = []
        let controller = controller(UpdaterStartPolicyTests.facts(), made: { checkers.append($0) })
        controller.startIfAllowed()
        #expect(checkers.first?.allowedChannels.isEmpty == true)
    }

    @Test func aBackgroundFindSetsTheReminderAndAttentionClearsIt() {
        var checkers: [FakeChecker] = []
        var changes: [String?] = []
        let controller = controller(UpdaterStartPolicyTests.facts(), made: { checkers.append($0) })
        controller.onReminderChange = { changes.append($0) }
        controller.startIfAllowed()
        #expect(controller.pendingVersion == nil)
        checkers.first?.onEvent?(.foundInBackground(version: "0.2.0"))
        #expect(controller.pendingVersion == "0.2.0")
        checkers.first?.onEvent?(.foundInBackground(version: "0.2.0"))
        checkers.first?.onEvent?(.reminderNoLongerNeeded)
        #expect(controller.pendingVersion == nil)
        #expect(changes == ["0.2.0", nil])
    }

    @Test func aRelaunchWaitsWhileBusyAndGoesOnAfterwards() {
        var checkers: [FakeChecker] = []
        var busy = true
        let controller = UpdateController(
            facts: UpdaterStartPolicyTests.facts(), settings: InMemorySettingsStore(), runningVersion: "0.1.0",
            isBusy: { busy },
            makeChecker: {
                let checker = FakeChecker()
                checkers.append(checker)
                return checker
            })
        controller.startIfAllowed()
        let checker = try? #require(checkers.first)
        checker?.readyToRelaunch()
        #expect(controller.hasPostponedRelaunch)
        controller.busyStateChanged()
        #expect(checker?.resumed == 0, "still busy: the relaunch stays held back")
        busy = false
        controller.busyStateChanged()
        #expect(checker?.resumed == 1)
        #expect(!controller.hasPostponedRelaunch)
        controller.busyStateChanged()
        #expect(checker?.resumed == 1)
    }

    /// A scripted ticker: counts the polls started and stopped, and fires on demand.
    final class FakePoll {
        var started = 0
        var stopped = 0
        var intervals: [TimeInterval] = []
        var tick: (@MainActor () -> Void)?
        var running: Bool { started > stopped }
        var starter: UpdateController.PollStarter {
            { [self] interval, tick in
                started += 1
                intervals.append(interval)
                self.tick = tick
                return { [self] in stopped += 1 }
            }
        }
        @MainActor func fire() { tick?() }
    }

    private func pollingController(
        busy: @escaping () -> Bool, poll: FakePoll, made: @escaping (FakeChecker) -> Void
    ) -> UpdateController {
        UpdateController(
            facts: UpdaterStartPolicyTests.facts(), settings: InMemorySettingsStore(), runningVersion: "0.1.0",
            isBusy: busy, startPolling: poll.starter,
            makeChecker: {
                let checker = FakeChecker()
                made(checker)
                return checker
            })
    }

    @Test func aPostponedRelaunchIsResumedByThePollOnceWhenBusyEndsAndThePollStops() {
        var busy = true
        var checkers: [FakeChecker] = []
        let poll = FakePoll()
        let controller = pollingController(busy: { busy }, poll: poll, made: { checkers.append($0) })
        controller.startIfAllowed()
        #expect(poll.started == 0, "no timer while nothing is postponed")
        checkers.first?.readyToRelaunch()
        #expect(poll.started == 1 && poll.running)
        #expect(poll.intervals == [5])
        poll.fire()
        poll.fire()
        #expect(checkers.first?.resumed == 0 && poll.running)
        busy = false
        poll.fire()
        #expect(checkers.first?.resumed == 1)
        #expect(!poll.running && poll.stopped == 1)
        poll.fire()
        #expect(checkers.first?.resumed == 1)
        #expect(poll.started == 1)
    }

    @Test func aSecondPostponementDoesNotStartASecondPoll() {
        var checkers: [FakeChecker] = []
        let poll = FakePoll()
        let controller = pollingController(busy: { true }, poll: poll, made: { checkers.append($0) })
        controller.startIfAllowed()
        checkers.first?.readyToRelaunch()
        checkers.first?.readyToRelaunch()
        #expect(poll.started == 1)
    }

    @Test func theCheckerStopsThePollWhenTheRelaunchWentOnByItself() {
        var checkers: [FakeChecker] = []
        let poll = FakePoll()
        let controller = pollingController(busy: { true }, poll: poll, made: { checkers.append($0) })
        controller.startIfAllowed()
        checkers.first?.readyToRelaunch()
        checkers.first?.postponed = false
        poll.fire()
        #expect(!poll.running)
        #expect(checkers.first?.resumed == 0)
    }

    @Test func nothingBusyNeverPostponesAndNeverPolls() {
        var checkers: [FakeChecker] = []
        let poll = FakePoll()
        let controller = pollingController(busy: { false }, poll: poll, made: { checkers.append($0) })
        controller.startIfAllowed()
        checkers.first?.readyToRelaunch()
        #expect(!controller.hasPostponedRelaunch)
        #expect(poll.started == 0)
    }

    @Test func aRelaunchIsNotHeldBackWhenNothingIsBusy() {
        var checkers: [FakeChecker] = []
        let controller = controller(UpdaterStartPolicyTests.facts(), made: { checkers.append($0) })
        controller.startIfAllowed()
        checkers.first?.readyToRelaunch()
        #expect(!controller.hasPostponedRelaunch)
    }

    @Test func aStartErrorLeavesTheUpdaterOff() {
        let controller = controller(UpdaterStartPolicyTests.facts(), error: Boom())
        controller.startIfAllowed()
        #expect(controller.state == .failed)
        #expect(!controller.canCheckForUpdates)
    }
}

/// The switch that keeps updates off until the owner's key exists (spec Step 4.3): no public key, and automatic
/// checks disabled, in the plist every build is made from.
@Suite struct UpdateInfoPlistTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func plist() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appending(path: "Resources/Info.plist"))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(value as? [String: Any])
    }

    @Test func theUpdaterIsSwitchedOff() throws {
        let plist = try Self.plist()
        #expect(plist["SUPublicEDKey"] == nil)
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(plist["SUAutomaticallyUpdate"] == nil)
        #expect(plist["SUEnableSystemProfiling"] == nil)
    }

    @Test func theFeedIsTheSiteOverHTTPSAndMustBeSigned() throws {
        let plist = try Self.plist()
        #expect(plist["SUFeedURL"] as? String == "https://lintelapp.com/appcast.xml")
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(plist["SUScheduledCheckInterval"] as? Int == 86400)
    }

    /// Only `SparkleUpdateChecker` may import Sparkle: everything else goes through `UpdateChecking`.
    @Test func onlyOneFileImportsSparkle() throws {
        let sources = Self.root.appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var importing: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.split(separator: "\n").contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == "import Sparkle"
            }) {
                importing.append(file.lastPathComponent)
            }
        }
        #expect(importing == ["SparkleUpdateChecker.swift"])
    }
}

/// The quiet reminder in the menu bar (spec Step 4.4): a menu item and a dot, never a window.
@MainActor
struct UpdateReminderMenuTests {
    private func actions(pending: @escaping () -> String?, show: @escaping () -> Void = {}) -> ShellMenuActions {
        var actions = ShellMenuActions(openPanel: {}, openSettings: {}, mainShortcut: { nil }, runCommand: { _ in })
        actions.pendingUpdate = pending
        actions.showUpdate = show
        return actions
    }

    @Test func withoutAFoundUpdateTheMenuHasNoUpdateItem() {
        let menu = NSMenu()
        StatusMenuBuilder(actions: actions(pending: { nil })).populate(menu, commands: [])
        #expect(menu.items.map(\.title) == ["Open Lintel", "", "Settings…", "About Lintel", "", "Quit Lintel"])
    }

    @Test func aFoundUpdateIsTheFirstMenuItemAndOpensTheUpdate() throws {
        var shown = 0
        let menu = NSMenu()
        let builder = StatusMenuBuilder(actions: actions(pending: { "0.2.0" }, show: { shown += 1 }))
        builder.populate(menu, commands: [])
        #expect(
            menu.items.map(\.title) == [
                "Update Available: 0.2.0…", "", "Open Lintel", "", "Settings…", "About Lintel", "", "Quit Lintel",
            ])
        let item = try #require(menu.items.first)
        #expect(item.identifier == StatusMenuBuilder.updateItemIdentifier)
        let action = try #require(item.action)
        _ = (item.target as? NSObject)?.perform(action, with: item)
        #expect(shown == 1)
    }

    @Test func theMenuFollowsTheReminderEachTimeItIsBuilt() {
        var pending: String? = "0.2.0"
        let menu = NSMenu()
        let builder = StatusMenuBuilder(actions: actions(pending: { pending }))
        builder.populate(menu, commands: [])
        #expect(menu.items.first?.title == "Update Available: 0.2.0…")
        pending = nil
        builder.populate(menu, commands: [])
        #expect(menu.items.first?.title == "Open Lintel")
    }

    /// A view with a chosen `isFlipped`; the menu bar's `NSStatusBarButton` is flipped.
    final class Canvas: NSView {
        let flippedCoordinates: Bool
        init(flipped: Bool) {
            flippedCoordinates = flipped
            super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            autoresizesSubviews = true
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { flippedCoordinates }
    }

    /// Distance of the dot from the top and right edges of its superview, whatever its coordinate system.
    private func insets(of badge: NSView, in canvas: Canvas) -> (top: CGFloat, right: CGFloat) {
        let top = canvas.isFlipped ? badge.frame.minY : canvas.bounds.maxY - badge.frame.maxY
        return (top, canvas.bounds.maxX - badge.frame.maxX)
    }

    @Test(arguments: [true, false])
    func theDotSitsInTheTopRightCornerAndStaysThereWhenTheButtonResizes(flipped: Bool) {
        let canvas = Canvas(flipped: flipped)
        let badge = UpdateBadgeView(frame: UpdateBadgeView.frame(in: canvas.bounds, flipped: flipped))
        badge.autoresizingMask = UpdateBadgeView.autoresizingMask(flipped: flipped)
        canvas.addSubview(badge)
        #expect(canvas.bounds.contains(badge.frame))
        let before = insets(of: badge, in: canvas)
        #expect(before.top < canvas.bounds.height / 2 && before.right < canvas.bounds.width / 2)
        canvas.setFrameSize(NSSize(width: 30, height: 24))
        let after = insets(of: badge, in: canvas)
        #expect(after.top == before.top && after.right == before.right)
        #expect(badge.frame.size == NSSize(width: UpdateBadgeView.diameter, height: UpdateBadgeView.diameter))
        #expect(badge.hitTest(NSPoint(x: badge.frame.midX, y: badge.frame.midY)) == nil)
    }

    @Test func theQAArgumentCarriesTheVersion() throws {
        let options = try #require(try QAOptions.parse(["--qa", "--qa-update-available", "0.2.0"]))
        #expect(options.updateAvailable == "0.2.0")
        #expect(throws: QAOptions.ParseError.self) {
            _ = try QAOptions.parse(["--qa", "--qa-update-available"])
        }
    }

    @Test func theQACheckerReportsTheUpdateAndClearsItWhenShown() {
        let controller = QAUpdateChecker.controller(version: "0.2.0", settings: InMemorySettingsStore())
        var changes: [String?] = []
        controller.onReminderChange = { changes.append($0) }
        controller.startIfAllowed()
        #expect(controller.state == .running)
        #expect(controller.pendingVersion == "0.2.0")
        controller.checkForUpdates()
        #expect(controller.pendingVersion == nil)
        #expect(changes == ["0.2.0", nil])
    }
}

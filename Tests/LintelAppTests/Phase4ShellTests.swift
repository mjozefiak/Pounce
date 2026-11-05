import AppKit
import Foundation
import LintelKit
import SwiftUI
import Testing

@testable import LintelApp

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// Needs Accessibility and the pasteboard, ordered first.
final class PastingPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "pasting", displayName: "Pasting", symbolName: "doc.on.clipboard", order: 1)

    init(context: PluginContext) {}

    var requiredPermissions: Set<Permission> { [.accessibility, .pasteboard] }
}

/// Needs Full Disk Access and Accessibility; off by default.
final class IndexingPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "indexing", displayName: "Indexing", symbolName: "doc", order: 2, defaultEnabled: false)

    init(context: PluginContext) {}

    var requiredPermissions: Set<Permission> { [.fullDiskAccess, .accessibility] }
}

/// Needs the microphone and System Audio Recording, like meeting notes; has one onboarding step.
final class RecordingPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "recording", displayName: "Recording", symbolName: "waveform", order: 3, defaultEnabled: false)

    init(context: PluginContext) {}

    var requiredPermissions: Set<Permission> { [.microphone, .systemAudioRecording] }

    var onboardingSteps: [OnboardingStep] {
        [OnboardingStep(id: "recording.intro", title: "Recording", symbolName: "waveform") { AnyView(EmptyView()) }]
    }
}

/// Answers from a table and counts reads.
@MainActor
final class FakePermissionsReader: PermissionsReader {
    var answers: [Permission: PermissionStatus] = [:]
    private(set) var reads: [Permission] = []

    func status(of permission: Permission) -> PermissionStatus {
        reads.append(permission)
        return answers[permission] ?? .notDetermined
    }
}

@MainActor
@Suite struct PermissionsPaneTests {
    @Test func rowsAreTheEnabledPluginsPermissionsWithTheirPlugins() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([PastingPlugin.self, IndexingPlugin.self])
        await host.start()
        let reader = FakePermissionsReader()
        let model = PermissionsModel(host: host, reader: reader) { _ in }

        // IndexingPlugin is off by default: only PastingPlugin's permissions are listed.
        #expect(
            model.requirements == [
                PermissionRequirement(permission: .accessibility, pluginNames: ["Pasting"]),
                PermissionRequirement(permission: .pasteboard, pluginNames: ["Pasting"]),
            ])

        await host.setEnabled(true, for: "indexing")
        #expect(
            model.requirements == [
                PermissionRequirement(permission: .accessibility, pluginNames: ["Pasting", "Indexing"]),
                PermissionRequirement(permission: .fullDiskAccess, pluginNames: ["Indexing"]),
                PermissionRequirement(permission: .pasteboard, pluginNames: ["Pasting"]),
            ])

        await host.setEnabled(false, for: "pasting")
        await host.setEnabled(false, for: "indexing")
        #expect(model.requirements.isEmpty)
    }

    @Test func refreshReadsEveryReadablePermission() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([PastingPlugin.self, IndexingPlugin.self])
        await host.start()
        let reader = FakePermissionsReader()
        reader.answers = [.accessibility: .granted, .pasteboard: .denied, .fullDiskAccess: .granted]
        let model = PermissionsModel(host: host, reader: reader) { _ in }

        // Before the first refresh the model answers from the reader instead of "unknown".
        #expect(model.status(of: .accessibility) == .granted)
        model.refresh()
        // Every permission has a row (the unused ones dimmed), so every readable one is read.
        #expect(Set(reader.reads) == Set(Permission.allCases.filter(\.isReadable)))
        #expect(model.status(of: .accessibility) == .granted)
        #expect(model.status(of: .pasteboard) == .denied)

        // "Check Again" picks up a change made in System Settings.
        reader.answers[.accessibility] = .denied
        model.refresh()
        #expect(model.status(of: .accessibility) == .denied)
    }

    @Test func openSettingsUsesEachPermissionsDeepLink() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([PastingPlugin.self])
        var opened: [URL] = []
        let model = PermissionsModel(host: host, reader: FakePermissionsReader()) { opened.append($0) }

        model.openSettings(for: .accessibility)
        model.openSettings(for: .fullDiskAccess)
        model.openSettings(for: .pasteboard)
        #expect(
            opened.map(\.absoluteString) == [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
                "x-apple.systempreferences:com.apple.preference.security",
            ])
    }

    @Test func systemAudioRecordingCannotBeReadAndIsNeverADenial() {
        let reader = SystemPermissionsReader(
            accessibilityOverride: .denied, fullDiskAccessOverride: .denied, microphoneOverride: .denied)
        #expect(reader.status(of: .systemAudioRecording) == .notDetermined)
        let permission = Permission.systemAudioRecording
        #expect(permission.statusText(.notDetermined) == "Can't be checked")
        #expect(permission.statusText(.notDetermined) != permission.statusText(.denied))
        #expect(permission.settingsURL.absoluteString.hasSuffix("?Privacy_AudioCapture"))
        #expect(!permission.explanation.isEmpty)
    }

    @Test func theSystemAudioRowAppearsOnlyWhenAnEnabledPluginRequiresIt() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([PastingPlugin.self, RecordingPlugin.self])
        await host.start()
        let model = PermissionsModel(host: host, reader: FakePermissionsReader()) { _ in }
        #expect(!model.requirements.map(\.permission).contains(.systemAudioRecording))

        await host.setEnabled(true, for: "recording")
        let row = model.requirements.first { $0.permission == .systemAudioRecording }
        #expect(row == PermissionRequirement(permission: .systemAudioRecording, pluginNames: ["Recording"]))
        model.refresh()
        #expect(model.status(of: .systemAudioRecording) == .notDetermined)

        await host.setEnabled(false, for: "recording")
        #expect(!model.requirements.map(\.permission).contains(.systemAudioRecording))
    }

    @Test func anUnreadablePermissionBlocksNeitherEnablingNorOnboarding() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([RecordingPlugin.self])
        await host.start()
        let reader = SystemPermissionsReader(
            accessibilityOverride: .granted, fullDiskAccessOverride: .granted, microphoneOverride: .granted)
        let model = PermissionsModel(host: host, reader: reader) { _ in }

        await host.setEnabled(true, for: "recording")
        #expect(model.requirements.map(\.permission).contains(.systemAudioRecording))
        #expect(model.status(of: .systemAudioRecording) == .notDetermined)
        #expect(host.isEnabled("recording"))
        #expect(host.state(of: "recording")?.isActive == true)
        let steps = host.entries.filter(\.state.isActive).flatMap(\.plugin.onboardingSteps)
        #expect(steps.map(\.id) == ["recording.intro"])

        let settings = AppSettings(store: InMemorySettingsStore())
        let hotkeys = HotkeyService(
            registrar: InMemoryHotkeyRegistrar(), settings: InMemorySettingsStore(), readOccupied: { [] })
        let controller = OnboardingController(hotkeys: hotkeys, settings: settings) { steps }
        settings.shortcutOnboardingCompleted = true
        #expect(controller.pendingPages.map(\.id) == ["recording.intro", "done"])
    }

    @Test func everyStateHasText() {
        let statuses: [PermissionStatus] = [.granted, .denied, .notDetermined]
        for permission in Permission.allCases {
            #expect(!permission.title.isEmpty)
            #expect(!permission.explanation.isEmpty)
            let texts = statuses.map { permission.statusText($0) }
            #expect(Set(texts).count == statuses.count, "\(permission) states must read differently")
        }
    }

    @Test func qaPasteboardAccessDecidesThePasteboardRow() {
        let expected: [PasteboardAccess: PermissionStatus] = [
            .alwaysAllow: .granted, .alwaysDeny: .denied, .ask: .notDetermined, .systemDefault: .notDetermined,
        ]
        for (access, status) in expected {
            let reader = SystemPermissionsReader(
                pasteboardName: NSPasteboard.Name("com.lintelapp.tests.\(UUID().uuidString)"),
                accessibilityOverride: .granted,
                fullDiskAccessOverride: .granted,
                pasteboardAccessOverride: access
            )
            #expect(reader.status(of: .pasteboard) == status)
        }
    }
}

/// A usage store whose reset fails.
actor FailingResetRecorder: UsageRecorder, RankingResettable {
    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {}
    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] { [:] }
    func resetRanking() async throws { throw TestError.eraseFailed }
}

/// A usage store without a reset.
actor PlainRecorder: UsageRecorder {
    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {}
    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] { [:] }
}

@MainActor
@Suite struct AdvancedPaneTests {
    @Test func resetRankingForgetsEveryUseAndRefreshesThePanel() async throws {
        let usage = InMemoryUsageRecorder()
        let app = ItemKey(pluginID: "apps", key: "com.example.notes")
        let file = ItemKey(pluginID: "files", key: "/notes.txt")
        try await usage.recordUse(of: app, queryPrefix: "no", at: Date())
        try await usage.recordUse(of: file, queryPrefix: nil, at: Date())
        var refreshed = 0
        let controls = AdvancedControls(usage: usage) { refreshed += 1 }

        #expect(await controls.resetRanking() == nil)
        #expect(refreshed == 1)
        #expect(try await usage.stats(for: [app, file], queryPrefix: "no").isEmpty)
        #expect(try await usage.mostUsed(pluginID: "apps", limit: 8, now: Date()).isEmpty)
    }

    @Test func aFailedResetReportsTheErrorAndDoesNotRefresh() async {
        var refreshed = 0
        let failing = AdvancedControls(usage: FailingResetRecorder()) { refreshed += 1 }
        #expect(await failing.resetRanking() != nil)
        let plain = AdvancedControls(usage: PlainRecorder()) { refreshed += 1 }
        #expect(await plain.resetRanking() != nil)
        #expect(refreshed == 0)
    }
}

@MainActor
@Suite struct WelcomeScreenTests {
    private func step(_ id: String) -> OnboardingStep {
        OnboardingStep(id: id, title: "Step \(id)", symbolName: "star") { AnyView(EmptyView()) }
    }

    private func makeController(
        _ store: InMemorySettingsStore, steps: [String]
    ) -> (OnboardingController, AppSettings) {
        let settings = AppSettings(store: store)
        let hotkeys = HotkeyService(registrar: InMemoryHotkeyRegistrar(), settings: store, readOccupied: { [] })
        let ids = steps
        let controller = OnboardingController(hotkeys: hotkeys, settings: settings) { [self] in ids.map(step) }
        controller.activatesApp = false
        return (controller, settings)
    }

    @Test func firstLaunchCombinesTheIntroTheShortcutAndEveryPluginStep() {
        let store = InMemorySettingsStore()
        let (controller, settings) = makeController(store, steps: ["clipboard.intro", "files.fullDiskAccess"])
        #expect(
            controller.pendingPages.map(\.id) == [
                "intro", "shortcut", "clipboard.intro", "files.fullDiskAccess", "done",
            ])

        // After an update only the new plugin step is pending: no introduction, no Shortcut step.
        settings.shortcutOnboardingCompleted = true
        settings.completedOnboardingSteps = ["clipboard.intro"]
        #expect(controller.pendingPages.map(\.id) == ["files.fullDiskAccess", "done"])

        settings.completedOnboardingSteps = ["clipboard.intro", "files.fullDiskAccess"]
        #expect(controller.pendingPages.isEmpty)
        #expect(!controller.hasPendingSteps)
    }

    @Test func flowMovesForwardAndBackAndRemembersFinishedPages() {
        let pages = [WelcomePage(kind: .intro), WelcomePage(kind: .shortcut), WelcomePage(kind: .plugin(step("a")))]
        let flow = WelcomeFlow(pages: pages)
        var finished: [String] = []
        var completed = 0
        flow.onFinish = { page, skipped in finished.append("\(page.id)\(skipped ? ":skip" : "")") }
        flow.onComplete = { completed += 1 }

        #expect(flow.isFirst)
        flow.back()
        #expect(flow.index == 0)
        flow.advance()
        flow.advance(skipping: true)
        #expect(flow.current?.id == "a")
        #expect(flow.isLast)
        #expect(flow.positionDescription == "Step 3 of 3: Step a")
        flow.back()
        #expect(flow.current?.id == "shortcut")
        flow.advance()
        flow.advance()
        #expect(finished == ["intro", "shortcut:skip", "shortcut", "a"])
        #expect(flow.finishedPageIDs == ["intro", "shortcut", "a"])
        #expect(completed == 1)

        #expect(WelcomeFlow(pages: pages, startAt: "a").index == 2)
        #expect(WelcomeFlow(pages: pages, startAt: "missing").index == 0)
    }

    @Test func skippingTheShortcutKeepsTheDefaultAndEveryStepIsRecorded() throws {
        let store = InMemorySettingsStore()
        store.setValue(.bool(true), forKey: SettingsKeys.hotkeyUserDefined)
        let (controller, settings) = makeController(store, steps: ["clipboard.intro", "files.fullDiskAccess"])
        controller.showPendingSteps()
        let flow = try #require(controller.flow)
        flow.advance()
        #expect(controller.currentPluginStep == nil)
        flow.advance(skipping: true)
        #expect(settings.shortcutOnboardingCompleted)
        #expect(store.value(forKey: SettingsKeys.hotkeyUserDefined) == nil)
        #expect(controller.currentPluginStep == "clipboard.intro")
        flow.advance(skipping: true)
        #expect(settings.completedOnboardingSteps == ["clipboard.intro"])
        flow.advance()
        #expect(settings.completedOnboardingSteps == ["clipboard.intro", "files.fullDiskAccess"])
        #expect(flow.current?.id == "done")
        flow.advance()
        #expect(controller.flow == nil)
        #expect(!controller.isVisible)
        #expect(!controller.hasPendingSteps)
    }

    @Test func usingTheShortcutKeepsTheRecordedOne() {
        let store = InMemorySettingsStore()
        store.setValue(.bool(true), forKey: SettingsKeys.hotkeyUserDefined)
        let (controller, settings) = makeController(store, steps: [])
        controller.showPendingSteps()
        controller.flow?.advance()
        controller.flow?.advance()
        #expect(settings.shortcutOnboardingCompleted)
        #expect(store.value(forKey: SettingsKeys.hotkeyUserDefined) == .bool(true))
        // The final page.
        controller.flow?.advance()
        #expect(controller.flow == nil)
    }

    @Test func closingSkipsOnlyTheStepOnScreen() {
        let store = InMemorySettingsStore()
        let (controller, settings) = makeController(store, steps: ["clipboard.intro", "files.fullDiskAccess"])
        settings.shortcutOnboardingCompleted = true
        controller.showPendingSteps()
        #expect(controller.currentPluginStep == "clipboard.intro")
        controller.close()
        #expect(settings.completedOnboardingSteps == ["clipboard.intro"])
        #expect(controller.pendingPages.map(\.id) == ["files.fullDiskAccess", "done"])
    }

    @Test func qaShowsEveryPageFromTheRequestedOne() {
        let store = InMemorySettingsStore()
        let (controller, settings) = makeController(store, steps: ["clipboard.intro"])
        settings.shortcutOnboardingCompleted = true
        settings.completedOnboardingSteps = ["clipboard.intro"]
        controller.showAllSteps(startingAt: "shortcut")
        defer { controller.close() }
        #expect(controller.flow?.pages.map(\.id) == ["intro", "shortcut", "clipboard.intro", "done"])
        #expect(controller.flow?.current?.id == "shortcut")
    }

    private func gatedController(steps: [String] = ["clipboard.intro"]) -> (OnboardingController, AppSettings) {
        let store = InMemorySettingsStore()
        let settings = AppSettings(store: store)
        let hotkeys = HotkeyService(registrar: InMemoryHotkeyRegistrar(), settings: store, readOccupied: { [] })
        let controller = OnboardingController(hotkeys: hotkeys, settings: settings) { [self] in steps.map(step) }
        controller.activatesApp = false
        return (controller, settings)
    }

    @Test func theFinalPageEndsEveryNonEmptyFlow() {
        let (enabled, enabledSettings) = gatedController()
        #expect(enabled.pendingPages.map(\.id) == ["intro", "shortcut", "clipboard.intro", "done"])
        enabled.showAllSteps()
        #expect(enabled.flow?.pages.last?.id == "done")
        enabled.close()

        // Nothing pending: no welcome screen, so no lone "You're set" page.
        enabledSettings.shortcutOnboardingCompleted = true
        enabledSettings.completedOnboardingSteps = ["clipboard.intro"]
        #expect(enabled.pendingPages.isEmpty)
        #expect(!enabled.hasPendingSteps)
        enabled.showPendingSteps()
        #expect(enabled.flow == nil)
    }

    @Test func theFinalPageCompletesTheFlow() {
        let (controller, _) = gatedController(steps: [])
        controller.showAllSteps(startingAt: "done")
        #expect(controller.flow?.current?.id == "done")
        var completed = false
        controller.flow?.onComplete = { completed = true }
        controller.flow?.advance()
        #expect(completed)
    }

    @Test func theFinalPageButtonOpensTheMainWindowThroughTheRouter() {
        var shown = 0
        var targets = MainWindowRouter.Targets()
        targets.showMainWindow = { shown += 1 }
        let router = MainWindowRouter(targets: targets)
        let (controller, _) = gatedController()
        controller.openMainWindow = { router.openMainWindow() }
        controller.openMainWindow()
        #expect(shown == 1)
    }

    // MARK: Layouts (step 6.5g)

    private func makeFooters(_ pages: [WelcomePage]) -> [WelcomeFooter] {
        pages.indices.map { index in
            WelcomeFooter(page: pages[index], isFirst: index == 0, isLast: index == pages.count - 1)
        }
    }

    @Test func theSingleColumnFooterFollowsThePrototype() {
        let pages = [
            WelcomePage(kind: .intro), WelcomePage(kind: .shortcut), WelcomePage(kind: .plugin(step("a"))),
            WelcomePage(kind: .done),
        ]
        let footers = makeFooters(pages)
        #expect(footers.map(\.primary) == [.continueToNext, .useShortcut, .continueToNext, .openNotes])
        #expect(footers.map(\.primaryTitle) == ["Continue", "Use This Shortcut", "Continue", "Open Lintel"])
        // Skip on every page as drawn; Back only after the first page.
        #expect(footers.map(\.showsSkip) == [true, true, true, true])
        #expect(footers.map(\.showsBack) == [false, true, true, true])
        #expect(makeFooters(Array(pages.prefix(3)))[2].primary == .done)
    }

    @Test func singleColumnPagesHaveTheMarkHeadingAndText() {
        #expect(WelcomePage(kind: .intro).heading == "Welcome to Lintel")
        #expect(WelcomePage(kind: .shortcut).heading == "Shortcut")
        #expect(WelcomePage(kind: .plugin(step("a"))).heading == "Step a")
        #expect(WelcomePage(kind: .done).heading == "You’re set")
        #expect(
            WelcomeColumnView.text(for: WelcomePage(kind: .intro), shortcut: nil)
                == "Search apps and files, paste from history, dictate, keep meeting notes. All on this Mac.")
        #expect(
            WelcomeColumnView.text(for: WelcomePage(kind: .shortcut), shortcut: nil)
                == ShortcutStepContent.explanation)
        #expect(WelcomeColumnView.text(for: WelcomePage(kind: .plugin(step("a"))), shortcut: nil) == nil)
        // Step 6.6f: a plugin page shows its step's line under the heading.
        let described = OnboardingStep(id: "b", title: "B", symbolName: "star", text: "What B does.") {
            AnyView(EmptyView())
        }
        #expect(WelcomeColumnView.text(for: WelcomePage(kind: .plugin(described)), shortcut: nil) == "What B does.")
        #expect(
            WelcomeColumnView.text(for: WelcomePage(kind: .done), shortcut: "⌘Space")
                == "Open Lintel with ⌘Space. Settings and meetings are in the Lintel window: click the Dock icon or press ⌘,."
        )
        #expect(
            WelcomeColumnView.text(for: WelcomePage(kind: .done), shortcut: nil)
                == "Settings and meetings are in the Lintel window: click the Dock icon or press ⌘,.")
    }

    @Test func singleColumnKeyboardActionsKeepTheCompletionKeys() throws {
        let store = InMemorySettingsStore()
        store.setValue(.bool(true), forKey: SettingsKeys.hotkeyUserDefined)
        let settings = AppSettings(store: store)
        let hotkeys = HotkeyService(registrar: InMemoryHotkeyRegistrar(), settings: store, readOccupied: { [] })
        let controller = OnboardingController(hotkeys: hotkeys, settings: settings) {
            [self] in ["clipboard.intro", "files.fullDiskAccess"].map(step)
        }
        controller.activatesApp = false
        var opened = 0
        controller.openMainWindow = { opened += 1 }
        controller.showPendingSteps()
        let flow = try #require(controller.flow)
        func footer() throws -> WelcomeFooter { try #require(WelcomeFooter(flow: flow)) }

        // Escape on the introduction moves on without recording anything.
        try footer().performSkip(flow)
        #expect(flow.current?.id == "shortcut")
        #expect(!settings.shortcutOnboardingCompleted)
        // Escape on the Shortcut step keeps the default, as in the step list.
        try footer().performSkip(flow)
        #expect(settings.shortcutOnboardingCompleted)
        #expect(store.value(forKey: SettingsKeys.hotkeyUserDefined) == nil)
        // Escape skips a plugin step, Return finishes the next one; both are recorded.
        try footer().performSkip(flow)
        try footer().performPrimary(flow, openMainWindow: controller.openMainWindow)
        #expect(settings.completedOnboardingSteps == ["clipboard.intro", "files.fullDiskAccess"])
        #expect(opened == 0)
        // Return on the final page opens the main window and closes the welcome screen.
        let finalFooter = try footer()
        #expect(finalFooter.primary == .openNotes)
        try footer().performPrimary(flow, openMainWindow: controller.openMainWindow)
        #expect(opened == 1)
        #expect(controller.flow == nil)
        #expect(!controller.hasPendingSteps)
    }

    @Test func escapeOnTheFinalPageClosesWithoutOpeningTheWindow() throws {
        let (controller, _) = gatedController(steps: [])
        var opened = 0
        controller.openMainWindow = { opened += 1 }
        controller.showAllSteps(startingAt: "done")
        let flow = try #require(controller.flow)
        try #require(WelcomeFooter(flow: flow)).performSkip(flow)
        #expect(opened == 0)
        #expect(controller.flow == nil)
    }

    @Test func theQAArgumentAcceptsEveryPageAndTheFinalOne() {
        let ids = ["clipboard.intro"]
        for id in ["intro", "shortcut", "clipboard.intro", "done"] {
            #expect(OnboardingController.isKnownPage(id, pluginStepIDs: ids))
        }
        #expect(!OnboardingController.isKnownPage("missing", pluginStepIDs: ids))

        let (controller, _) = gatedController()
        controller.showAllSteps(startingAt: "done")
        defer { controller.close() }
        #expect(controller.flow?.current?.id == "done")
    }
}

@MainActor
@Suite struct AboutWindowTests {
    @Test func readsTheVersionAndTheNoticesFromTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lintel-about-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.lintelapp.tests.about", "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45", "NSHumanReadableCopyright": "Copyright Example",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appending(path: "Contents/Info.plist"))
        try Data("Example notices".utf8).write(to: resources.appending(path: "THIRD_PARTY_NOTICES.txt"))

        let info = AboutInfo(bundle: try #require(Bundle(url: root)))
        #expect(
            info == AboutInfo(version: "1.2.3", build: "45", copyright: "Copyright Example", notices: "Example notices")
        )
        #expect(info.versionText == "Version 1.2.3 (45)")
    }

    @Test func anUnbundledBuildSaysSo() {
        let info = AboutInfo(version: nil, build: nil, copyright: nil, notices: nil)
        #expect(info.versionText == "Development build")
        #expect(AboutInfo(version: "1.0.0", build: nil, copyright: nil, notices: nil).versionText == "Version 1.0.0")
        #expect(!AboutView.missingNotices.isEmpty)
    }

    @Test func theAppBundleShipsTheNotices() throws {
        let notices = try String(
            contentsOf: repositoryRoot.appending(path: "Resources/THIRD_PARTY_NOTICES.txt"), encoding: .utf8)
        #expect(notices.contains("SQLCipher"))
        let script = try String(contentsOf: repositoryRoot.appending(path: "scripts/make-app.sh"), encoding: .utf8)
        #expect(script.contains("Contents/Resources/THIRD_PARTY_NOTICES.txt"))
    }

    @Test func theMenuItemOpensLintelsAboutWindow() throws {
        var opened = 0
        var actions = ShellMenuActions(openPanel: {}, openSettings: {}, mainShortcut: { nil }, runCommand: { _ in })
        actions.showAbout = { opened += 1 }
        let menu = NSMenu()
        let builder = StatusMenuBuilder(actions: actions)
        builder.populate(menu, commands: [])
        let about = try #require(menu.items.first { $0.title == "About Lintel" })
        let action = try #require(about.action)
        _ = (about.target as? NSObject)?.perform(action, with: about)
        #expect(opened == 1)
        withExtendedLifetime(builder) {}
    }
}

/// Accessibility audit (spec step 4.3): what VoiceOver hears where the screen shows symbols.
@Suite struct AccessibilityAuditTests {
    @Test func footerKeysAreSpokenInWords() {
        #expect(ActionFooter.spokenKeys(KeyShortcut(key: "\r")) == "Return")
        #expect(ActionFooter.spokenKeys(KeyShortcut(key: "\r", modifiers: .command)) == "Command-Return")
        #expect(ActionFooter.spokenKeys(KeyShortcut(key: "c", modifiers: [.command, .shift])) == "Shift-Command-C")
        #expect(ActionFooter.spokenKeys(KeyShortcut(key: "x", modifiers: .control)) == "Control-X")
        #expect(ActionFooter.spokenKeys(KeyShortcut(key: "\u{7F}", modifiers: [.option])) == "Option-Delete")
        #expect(ActionFooter.spokenKeys(KeyShortcut(key: " ")) == "Space")

        let reveal = ResultAction(
            id: "reveal", title: "Show in Finder", symbolName: "folder",
            shortcut: KeyShortcut(key: "\r", modifiers: .command)
        ) { _ in }
        #expect(ActionFooter.spokenLabel(reveal) == "Show in Finder, Command-Return")
        let plain = ResultAction(id: "open", title: "Open", symbolName: "arrow.up.forward") { _ in }
        #expect(ActionFooter.spokenLabel(plain) == "Open")
        // The screen still shows the symbols.
        #expect(ActionFooter.keys(KeyShortcut(key: "\r", modifiers: .command)) == "⌘⏎")
    }
}

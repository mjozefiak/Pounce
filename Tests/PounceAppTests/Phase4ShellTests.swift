import AppKit
import Foundation
import PounceKit
import SwiftUI
import Testing

@testable import PounceApp

/// Needs Accessibility and the pasteboard, ordered first.
final class PastingPlugin: PouncePlugin {
    static let manifest = PluginManifest(
        id: "pasting", displayName: "Pasting", symbolName: "doc.on.clipboard", order: 1)

    init(context: PluginContext) {}

    var requiredPermissions: Set<Permission> { [.accessibility, .pasteboard] }
}

/// Needs Full Disk Access and Accessibility; off by default.
final class IndexingPlugin: PouncePlugin {
    static let manifest = PluginManifest(
        id: "indexing", displayName: "Indexing", symbolName: "doc", order: 2, defaultEnabled: false)

    init(context: PluginContext) {}

    var requiredPermissions: Set<Permission> { [.fullDiskAccess, .accessibility] }
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

    @Test func refreshReadsOnlyTheRequiredPermissions() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([PastingPlugin.self, IndexingPlugin.self])
        await host.start()
        let reader = FakePermissionsReader()
        reader.answers = [.accessibility: .granted, .pasteboard: .denied, .fullDiskAccess: .granted]
        let model = PermissionsModel(host: host, reader: reader) { _ in }

        #expect(model.status(of: .accessibility) == .notDetermined)
        model.refresh()
        #expect(Set(reader.reads) == [.accessibility, .pasteboard])
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

    @Test func everyStateHasTextAndASymbol() {
        let statuses: [PermissionStatus] = [.granted, .denied, .notDetermined]
        for permission in Permission.allCases {
            #expect(!permission.title.isEmpty)
            #expect(!permission.explanation.isEmpty)
            #expect(NSImage(systemSymbolName: permission.symbolName, accessibilityDescription: nil) != nil)
            let texts = statuses.map { permission.statusText($0) }
            #expect(Set(texts).count == statuses.count, "\(permission) states must read differently")
        }
        for status in statuses {
            #expect(NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil) != nil)
        }
        #expect(Set(statuses.map(\.symbolName)).count == statuses.count)
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
@Suite struct SettingsTabTests {
    @Test func shellPanesSurroundThePluginPanes() {
        #expect(SettingsWindowController.tabIndex(of: .general, pluginPaneCount: 3) == 0)
        #expect(SettingsWindowController.tabIndex(of: .features, pluginPaneCount: 3) == 1)
        #expect(SettingsWindowController.tabIndex(of: .permissions, pluginPaneCount: 3) == 5)
        #expect(SettingsWindowController.tabIndex(of: .advanced, pluginPaneCount: 3) == 6)
        #expect(SettingsWindowController.tabIndex(of: .permissions, pluginPaneCount: 0) == 2)
        #expect(SettingsWindowController.tabIndex(ofPlugin: "files", in: ["apps", "files"]) == 3)
        #expect(SettingsWindowController.tabIndex(ofPlugin: "gone", in: ["apps"]) == nil)
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
        #expect(controller.pendingPages.map(\.id) == ["intro", "shortcut", "clipboard.intro", "files.fullDiskAccess"])

        // After an update only the new plugin step is pending: no introduction, no Shortcut step.
        settings.shortcutOnboardingCompleted = true
        settings.completedOnboardingSteps = ["clipboard.intro"]
        #expect(controller.pendingPages.map(\.id) == ["files.fullDiskAccess"])

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
        #expect(flow.current?.isSkippable == false)
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
        #expect(controller.pendingPages.map(\.id) == ["files.fullDiskAccess"])
    }

    @Test func qaShowsEveryPageFromTheRequestedOne() {
        let store = InMemorySettingsStore()
        let (controller, settings) = makeController(store, steps: ["clipboard.intro"])
        settings.shortcutOnboardingCompleted = true
        settings.completedOnboardingSteps = ["clipboard.intro"]
        controller.showAllSteps(startingAt: "shortcut")
        defer { controller.close() }
        #expect(controller.flow?.pages.map(\.id) == ["intro", "shortcut", "clipboard.intro"])
        #expect(controller.flow?.current?.id == "shortcut")
    }
}

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

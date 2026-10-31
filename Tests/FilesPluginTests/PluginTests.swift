import Foundation
import PounceCore
import PounceKit
import Testing

@testable import FilesPlugin

@MainActor
@Suite("FilesPlugin")
struct FilesPluginTests {
    private static let fixture = [
        "home/Projects/Quarterly Report.pages",
        "home/Projects/notes.txt",
        "home/Projects/node_modules/left-pad/index.js",
        "home/Desktop/desk-plan.txt",
        "home/Documents/tax-form.pdf",
        "home/Downloads/installer.dmg",
        "home/.hidden-config",
    ]

    @Test func waitsForSetupBeforeTheFirstScan() async throws {
        let harness = try PluginHarness()
        try harness.directory.make(Self.fixture)
        try await harness.plugin.activate()
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.plugin.state.status.phase == .waiting)
        #expect(harness.plugin.index.snapshot.liveCount == 0)
        #expect(harness.plugin.searchStatus.map(\.id) == ["files.setup"])

        harness.plugin.completeSetup()
        #expect(await eventually { harness.plugin.state.status.phase == .ready })
        #expect(try await harness.names("quarterly") == ["Quarterly Report.pages"])
        await harness.plugin.deactivate()
    }

    @Test func withoutFullDiskAccessProtectedFoldersAndExclusionsAreSkipped() async throws {
        let harness = try PluginHarness(settings: ["plugins.files.setupCompleted": .bool(true)])
        try harness.directory.make(Self.fixture)
        try await harness.plugin.activate()
        #expect(await eventually { harness.plugin.state.status.phase == .ready })

        #expect(try await harness.names("notes") == ["notes.txt"])
        #expect(try await harness.names("desk-plan").isEmpty)
        #expect(try await harness.names("tax-form").isEmpty)
        #expect(try await harness.names("installer").isEmpty)
        #expect(try await harness.names("left-pad").isEmpty)
        #expect(try await harness.names("hidden-config").isEmpty)
        #expect(harness.plugin.searchStatus.map(\.id) == ["files.access"])
        await harness.plugin.deactivate()
    }

    @Test func addingAProtectedFolderIndexesIt() async throws {
        let harness = try PluginHarness(settings: ["plugins.files.setupCompleted": .bool(true)])
        try harness.directory.make(Self.fixture)
        try await harness.plugin.activate()
        #expect(await eventually { harness.plugin.state.status.phase == .ready })

        harness.plugin.settings.setProtected(.desktop, added: true)
        #expect(try await eventually { try await harness.names("desk-plan") == ["desk-plan.txt"] })
        #expect(try await harness.names("tax-form").isEmpty)
        await harness.plugin.deactivate()
    }

    @Test func fullDiskAccessIndexesProtectedFolders() async throws {
        let harness = try PluginHarness(settings: ["plugins.files.setupCompleted": .bool(true)])
        harness.permissions.fullDiskAccess = .granted
        try harness.directory.make(Self.fixture)
        try await harness.plugin.activate()
        #expect(await eventually { harness.plugin.state.status.phase == .ready })

        #expect(try await harness.names("desk-plan") == ["desk-plan.txt"])
        #expect(try await harness.names("tax-form") == ["tax-form.pdf"])
        #expect(harness.plugin.searchStatus.isEmpty)
        await harness.plugin.deactivate()
    }

    @Test func grantingAccessLaterReplans() async throws {
        let harness = try PluginHarness(settings: ["plugins.files.setupCompleted": .bool(true)])
        try harness.directory.make(Self.fixture)
        try await harness.plugin.activate()
        #expect(await eventually { harness.plugin.state.status.phase == .ready })
        #expect(try await harness.names("tax-form").isEmpty)

        harness.permissions.fullDiskAccess = .granted
        harness.plugin.refreshAccess()
        #expect(try await eventually { try await harness.names("tax-form") == ["tax-form.pdf"] })
        await harness.plugin.deactivate()
    }

    @Test func dismissedAccessNoticeStaysHidden() async throws {
        let harness = try PluginHarness(settings: ["plugins.files.setupCompleted": .bool(true)])
        try await harness.plugin.activate()
        let notice = try #require(harness.plugin.searchStatus.first { $0.id == "files.access" })
        #expect(notice.actions.map(\.id) == ["files.access.open", "files.access.dismiss"])
        guard case .run(let dismiss) = notice.actions[1].kind else {
            Issue.record("dismiss is not a run action")
            return
        }
        dismiss()
        #expect(harness.plugin.searchStatus.allSatisfy { $0.id != "files.access" })
        #expect(harness.settings.value(forKey: "plugins.files.accessNoticeDismissed") == .bool(true))
        await harness.plugin.deactivate()
    }

    @Test func allowOpensTheFullDiskAccessSettings() async throws {
        let harness = try PluginHarness()
        harness.plugin.openAccessSettings()
        #expect(await eventually { !harness.workspace.opened.isEmpty })
        #expect(harness.workspace.opened.first?.absoluteString.contains("Privacy_AllFiles") == true)
    }

    @Test func statusesShowProgressWhileScanning() {
        let statuses = FilesPlugin.statuses(
            status: IndexStatus(phase: .scanning, count: 1200), setupCompleted: true, fullDiskAccess: .granted,
            noticeDismissed: false, openAccessSettings: {}, dismissNotice: {})
        #expect(statuses.map(\.id) == ["files.progress"])
        #expect(statuses.first?.style == .progress)

        let ready = FilesPlugin.statuses(
            status: IndexStatus(phase: .ready, count: 1200), setupCompleted: true, fullDiskAccess: .denied,
            noticeDismissed: true, openAccessSettings: {}, dismissNotice: {})
        #expect(ready.isEmpty)
    }

    @Test func eraseDataEmptiesTheIndex() async throws {
        let harness = try PluginHarness(settings: ["plugins.files.setupCompleted": .bool(true)])
        try harness.directory.make(Self.fixture)
        try await harness.plugin.activate()
        #expect(await eventually { harness.plugin.state.status.phase == .ready })
        await harness.plugin.deactivate()
        try await harness.plugin.eraseData()
        #expect(harness.plugin.index.snapshot.liveCount == 0)
    }

    @Test func manifestAndContributions() throws {
        let harness = try PluginHarness()
        #expect(FilesPlugin.manifest.id == "files")
        #expect(harness.plugin.requiredPermissions == [.fullDiskAccess])
        #expect(harness.plugin.onboardingSteps.map(\.id) == ["files.fullDiskAccess"])
        #expect(harness.plugin.searchSources.map(\.id) == ["files.names"])
        #expect(harness.plugin.settingsPane() != nil)
    }
}

@MainActor
@Suite("File actions")
struct FileActionTests {
    private func setUp() async throws -> (PluginHarness, any SearchSource, Candidate) {
        let harness = try PluginHarness(settings: ["plugins.files.setupCompleted": .bool(true)])
        try harness.directory.make(["home/Projects/budget.numbers"])
        try await harness.plugin.activate()
        #expect(await eventually { harness.plugin.state.status.phase == .ready })
        let source = try #require(harness.plugin.searchSources.first)
        let candidate = try #require(try await source.search(TextNormalizer.query("budget"), limit: 5).first)
        return (harness, source, candidate)
    }

    @Test func resultCarriesPathKeyAndAbbreviatedFolder() async throws {
        let (harness, _, candidate) = try await setUp()
        #expect(
            candidate.itemKey == ItemKey(pluginID: "files", key: harness.directory.sub("home/Projects/budget.numbers")))
        #expect(candidate.subtitle == "~/Projects")
        await harness.plugin.deactivate()
    }

    @Test func openRevealAndCopyPath() async throws {
        let (harness, source, candidate) = try await setUp()
        let actions = source.actions(for: candidate)
        #expect(
            actions.map(\.id) == [
                FileActions.openID, FileActions.revealID, FileActions.copyPathID, FileActions.copyFileID,
            ])
        let panel = FakePanel()
        let context = ActionContext(previousApp: nil, panel: panel, query: TextNormalizer.query("budget"))
        let path = harness.directory.sub("home/Projects/budget.numbers")

        try await actions[0].perform(context)
        #expect(harness.workspace.opened.map(\.path) == [path])
        try await actions[1].perform(context)
        #expect(harness.workspace.revealed.map { $0.map(\.path) } == [[path]])
        try await actions[2].perform(context)
        #expect(harness.pasteboard.string() == path)
        try await actions[3].perform(context)
        let item = try #require(harness.pasteboard.items.first)
        #expect(
            item.data(for: "public.file-url").map { String(decoding: $0, as: UTF8.self) }
                == URL(filePath: path).absoluteString)
        #expect(panel.confirmations.count == 2)
        let uses = await harness.usage.uses
        #expect(uses.count == 4)
        #expect(uses.allSatisfy { $0.0 == candidate.itemKey })

        let recent = try await source.search(TextNormalizer.query(""), limit: 5)
        #expect(recent.map(\.itemKey) == [candidate.itemKey])
        await harness.plugin.deactivate()
    }

    @Test func actionsOnAMissingFileFail() async throws {
        let (harness, source, candidate) = try await setUp()
        try FileManager.default.removeItem(atPath: candidate.itemKey.key)
        let context = ActionContext(previousApp: nil, panel: FakePanel())
        let actions = source.actions(for: candidate)
        await #expect(throws: FileActionError.missing) { try await actions[0].perform(context) }
        await #expect(throws: FileActionError.missing) { try await actions[3].perform(context) }
        #expect(harness.workspace.opened.isEmpty)
        await harness.plugin.deactivate()
    }
}

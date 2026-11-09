import AppKit
import Foundation
import LintelCore
import LintelKit
import Testing

@testable import LintelApp

/// Spec step 0.1b. Serialized because the test plugins share `LifecycleLog`. These tests also run
/// under `swift test --sanitize=thread` in CI.
@Suite(.serialized) struct PluginHostTests {
    let env: TestEnvironment

    init() throws {
        env = try TestEnvironment()
        LifecycleLog.shared.reset()
    }

    @Test func enabledPluginIsActivatedAndDisabledOneIsNot() async {
        defer { env.tearDown() }
        let host = env.makeHost([AlphaPlugin.self, BetaPlugin.self])

        await host.start()

        #expect(host.state(of: "alpha")?.isActive == true)
        #expect(host.state(of: "beta").map(isDisabled) == true)
        #expect(LifecycleLog.shared.events == ["alpha.activate"])
    }

    @Test func recoverAtLaunchRunsOnceForADisabledPlugin() async {
        defer { env.tearDown() }
        RecoveryScript.shared.reset([.done])
        let host = env.makeHost([LaunchRecoveryPlugin.self])

        await host.start()
        await host.waitForRecoveries()
        await host.start()
        await host.waitForRecoveries()

        #expect(host.state(of: "launchrecovery").map(isDisabled) == true)
        #expect(RecoveryScript.shared.callCount == 1)
        #expect(host.recoveryOutcomes["launchrecovery"] == .done)
    }

    @Test func deferredRecoveryIsRetriedOnRequestUntilDone() async {
        defer { env.tearDown() }
        RecoveryScript.shared.reset([.deferred, .done])
        let host = env.makeHost([LaunchRecoveryPlugin.self])

        await host.start()
        await host.waitForRecoveries()
        #expect(host.recoveryOutcomes["launchrecovery"] == .deferred)

        host.retryDeferredRecoveries()
        await host.waitForRecoveries()
        #expect(host.recoveryOutcomes["launchrecovery"] == .done)

        host.retryDeferredRecoveries()
        await host.waitForRecoveries()
        #expect(RecoveryScript.shared.callCount == 2)
    }

    @MainActor
    @Test func appActivationRetriesADeferredRecovery() async {
        defer { env.tearDown() }
        RecoveryScript.shared.reset([.deferred, .done])
        let coordinator = AppCoordinator(
            environment: env.environment, pluginTypes: [LaunchRecoveryPlugin.self],
            registrar: InMemoryHotkeyRegistrar(), occupiedShortcuts: { [] }, launchAtLogin: NoLaunchAtLogin())
        let center = NotificationCenter()
        coordinator.activationCenter = center
        await coordinator.host.start()
        await coordinator.host.waitForRecoveries()
        coordinator.observeActivationForRecovery()
        #expect(coordinator.host.recoveryOutcomes["launchrecovery"] == .deferred)

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await coordinator.host.waitForRecoveries()
        #expect(coordinator.host.recoveryOutcomes["launchrecovery"] == .done)
        #expect(RecoveryScript.shared.callCount == 2)
    }

    @Test func recoveryBoundGivesDeferredWithoutWaitingForHungWork() async {
        let outcome = await withDeadline(.milliseconds(50), clock: ContinuousClock()) {
            await Task.detached { blockCurrentThread(microseconds: 1_500_000) }.value
            return RecoveryOutcome.done
        }
        #expect(outcome == nil)
    }

    @Test func aRetryNeverStartsASecondRecoveryBesideOneThatIsStillRunning() async {
        defer { env.tearDown() }
        OverrunRecoveryPlugin.reset()
        defer { OverrunRecoveryPlugin.release() }
        let host = env.makeHost([OverrunRecoveryPlugin.self], recoveryBudget: .milliseconds(30))
        await host.start()
        await host.waitForRecoveries()
        #expect(host.recoveryOutcomes["overrunrecovery"] == .deferred)
        // The first call is past its bound but still running: the retries wait for it, they do not overlap it.
        host.retryDeferredRecoveries()
        host.retryDeferredRecoveries()
        await host.waitForRecoveries()
        #expect(OverrunRecoveryPlugin.entered.withLock { $0 } == 1)
    }

    @Test func defaultPluginRecoversAsDone() async {
        defer { env.tearDown() }
        let outcome = await AlphaPlugin.recoverAtLaunch(context: env.environment.makeContext(for: AlphaPlugin.manifest))
        #expect(outcome == .done)
    }

    @Test func disablingDeactivatesAndEnablingActivatesWithoutRestart() async {
        defer { env.tearDown() }
        let host = env.makeHost([AlphaPlugin.self])
        await host.start()

        await host.setEnabled(false, for: "alpha")
        #expect(host.state(of: "alpha").map(isDisabled) == true)
        #expect(env.settings.value(forKey: "plugins.alpha.enabled") == .bool(false))

        await host.setEnabled(true, for: "alpha")
        #expect(host.state(of: "alpha")?.isActive == true)
        #expect(LifecycleLog.shared.events == ["alpha.activate", "alpha.deactivate", "alpha.activate"])
    }

    @Test func persistedToggleWinsOverTheManifestDefault() async {
        defer { env.tearDown() }
        env.settings.setValue(.bool(true), forKey: "plugins.beta.enabled")
        env.settings.setValue(.bool(false), forKey: "plugins.alpha.enabled")
        let host = env.makeHost([AlphaPlugin.self, BetaPlugin.self])

        await host.start()

        #expect(host.state(of: "alpha").map(isDisabled) == true)
        #expect(host.state(of: "beta")?.isActive == true)
    }

    @Test func throwingActivationFailsOnlyThatPlugin() async {
        defer { env.tearDown() }
        let host = env.makeHost([FailingPlugin.self, AlphaPlugin.self])

        await host.start()

        guard case .failed(let error) = host.state(of: "failing") else {
            Issue.record("expected failed, got \(String(describing: host.state(of: "failing")))")
            return
        }
        #expect(error as? TestError == .activationFailed)
        #expect(host.state(of: "alpha")?.isActive == true)
        // The failed activation is cleaned up with deactivate().
        #expect(LifecycleLog.shared.events == ["failing.activate", "failing.deactivate", "alpha.activate"])
        // A failed plugin contributes nothing.
        #expect(host.activeCommands.map(\.id) == ["alpha.open"])
        #expect(host.activeSources.map(\.source.id) == ["alpha.instant"])
    }

    @Test func disabledPluginRegistersNoCommands() async {
        defer { env.tearDown() }
        let host = env.makeHost([AlphaPlugin.self, BetaPlugin.self])
        await host.start()
        #expect(host.activeCommands.map(\.id) == ["alpha.open"])

        await host.setEnabled(false, for: "alpha")
        #expect(host.activeCommands.isEmpty)

        await host.setEnabled(true, for: "beta")
        #expect(host.activeCommands.map(\.id) == ["beta.open"])
    }

    @Test func pluginsAreOrderedByManifestOrder() {
        defer { env.tearDown() }
        let host = env.makeHost([StuckPlugin.self, AlphaPlugin.self, FailingPlugin.self])
        #expect(host.entries.map(\.manifest.id) == ["failing", "alpha", "stuck"])
    }

    @Test func duplicatePluginIDsAreSkipped() {
        defer { env.tearDown() }
        let host = env.makeHost([AlphaPlugin.self, AlphaPlugin.self])
        #expect(host.entries.count == 1)
    }

    @Test func overBudgetSourceDoesNotBlockTheOthers() async {
        defer { env.tearDown() }
        let host = env.makeHost([AlphaPlugin.self, StuckPlugin.self], budget: .milliseconds(100))
        await host.start()

        let started = ContinuousClock.now
        let results = await host.query(NormalizedQuery(raw: "Te", normalized: "te"), limit: 10)
        let elapsed = ContinuousClock.now - started

        // The stuck source blocks for 5 s; the query returns at its 100 ms budget. The bound is far from both, so
        // a slow CI machine cannot make the test flaky.
        #expect(elapsed < .seconds(3))
        #expect(results.map(\.sourceID) == ["alpha.instant", "stuck", "throwing"])
        guard case .results(let candidates) = results[0].outcome else {
            Issue.record("alpha source should answer")
            return
        }
        #expect(candidates.map(\.title) == ["Result for Te"])
        guard case .timedOut = results[1].outcome else {
            Issue.record("stuck source should time out")
            return
        }
        guard case .failed = results[2].outcome else {
            Issue.record("throwing source should fail on its own")
            return
        }
    }

    @Test func activationCreatesAPrivateStorageDirectory() async throws {
        defer { env.tearDown() }
        let host = env.makeHost([AlphaPlugin.self])
        await host.start()

        let directory = env.environment.storageDirectory(for: "alpha")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(directory.path.hasSuffix("/Plugins/alpha"))
    }

    @Test func eraseDataRemovesStorageAndPluginDataThenReactivates() async throws {
        defer { env.tearDown() }
        let host = env.makeHost([StorageWritingPlugin.self])
        await host.start()
        let directory = env.environment.storageDirectory(for: "storage")
        let file = directory.appending(path: "data.bin")
        let stale = directory.appending(path: "stale.bin")
        try Data("old".utf8).write(to: stale)
        let usage = env.environment.usage
        let own = ItemKey(pluginID: "storage", key: "item")
        let other = ItemKey(pluginID: "alpha", key: "item")
        try await usage.recordUse(of: own, queryPrefix: "it", at: Date())
        try await usage.recordUse(of: other, queryPrefix: "it", at: Date())

        try await host.eraseData(for: "storage")

        // The plugin's ranking rows go too; another plugin's stay.
        let stats = try await usage.stats(for: [own, other], queryPrefix: "it")
        #expect(stats[own] == nil)
        #expect(stats[other]?.queryAssociationCount == 1)

        #expect(LifecycleLog.shared.events == ["storage.activate", "storage.erase", "storage.activate"])
        // The directory was deleted: the stale file is gone, re-activation wrote a fresh one.
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(host.state(of: "storage")?.isActive == true)
        #expect(throws: Never.self) {
            _ = try env.environment.keychain.readGenericPassword(service: "storage", account: "key")
        }
    }

    /// Spec step 1.2b: the Features switch drives `PluginHost` and the shell follows.
    @MainActor
    @Test func featuresSwitchAndEraseDriveTheHost() async throws {
        defer { env.tearDown() }
        let host = env.makeHost([AlphaPlugin.self, StorageWritingPlugin.self])
        await host.start()
        var changes = 0
        let controls = FeatureControls(host: host) { changes += 1 }

        await controls.setEnabled(false, for: "alpha")
        #expect(!controls.isEnabled("alpha"))
        #expect(host.state(of: "alpha").map(isDisabled) == true)
        #expect(env.settings.value(forKey: "plugins.alpha.enabled") == .bool(false))
        #expect(!host.activeCommands.contains { $0.id == "alpha.open" })
        #expect(changes == 1)

        await controls.setEnabled(true, for: "alpha")
        #expect(controls.isEnabled("alpha"))
        #expect(host.state(of: "alpha")?.isActive == true)
        #expect(host.activeCommands.contains { $0.id == "alpha.open" })
        #expect(changes == 2)

        #expect(await controls.erase("storage") == nil)
        #expect(LifecycleLog.shared.events.contains("storage.erase"))
        #expect(changes == 3)
    }

    /// A failed "Erase Data" is reported to the pane instead of being swallowed.
    @MainActor
    @Test func failedEraseReturnsAMessage() async {
        defer { env.tearDown() }
        let host = env.makeHost([UnerasablePlugin.self])
        await host.start()
        var changes = 0
        let controls = FeatureControls(host: host) { changes += 1 }

        let message = await controls.erase("unerasable")

        #expect(message?.isEmpty == false)
        #expect(changes == 1)
    }

    @Test func stopDeactivatesEveryPlugin() async {
        defer { env.tearDown() }
        let host = env.makeHost([AlphaPlugin.self, BetaPlugin.self])
        await host.start()

        await host.stop()

        #expect(host.activeCommands.isEmpty)
        #expect(LifecycleLog.shared.events == ["alpha.activate", "alpha.deactivate", "beta.deactivate"])
    }

    @Test func overlappingTogglesRunInOrder() async {
        defer { env.tearDown() }
        let host = env.makeHost([AlphaPlugin.self])
        await host.start()

        async let off: Void = host.setEnabled(false, for: "alpha")
        async let on: Void = host.setEnabled(true, for: "alpha")
        _ = await (off, on)

        // Whatever the interleaving, every activate is followed by a deactivate before the next one.
        var active = false
        for event in LifecycleLog.shared.events {
            if event == "alpha.activate" {
                #expect(!active)
                active = true
            } else if event == "alpha.deactivate" {
                active = false
            }
        }
    }

    /// Spec step 2.2: the banner's Try Again (`.enablePlugin`) re-runs activation on a failed plugin.
    @Test func aFailedPluginActivatesAgainThroughTheBannersEnablePlugin() async {
        defer { env.tearDown() }
        RecoveringPlugin.failuresLeft = 1
        let host = env.makeHost([RecoveringPlugin.self])
        await host.start()
        guard case .failed = host.state(of: "recovering") else {
            Issue.record("expected the first activation to fail")
            return
        }
        var changed = 0
        var navigation = SettingsHostModel.Navigation()
        navigation.pluginsChanged = { changed += 1 }
        let model = SettingsHostModel(host: host, reader: FakePermissionsReader(), navigation: navigation)
        model.show("recovering")
        #expect(model.banner?.level == .error)
        let retry = model.banner?.actions.first
        #expect(retry.map(ActionKind.init) == .enablePlugin)

        if let retry { await model.perform(retry) }
        #expect(host.state(of: "recovering")?.isActive == true)
        #expect(LifecycleLog.shared.events.filter { $0 == "recovering.activate" }.count == 2)
        #expect(changed == 1)
        #expect(model.banner?.level == .ok)
        #expect(model.attention["recovering"] == nil)
    }

    private func isDisabled(_ state: PluginState) -> Bool {
        if case .disabled = state { return true }
        return false
    }
}

/// Review H2: enabling or erasing a plugin waits for its recovery, which owns the journal until it answers.
@Suite(.serialized) struct RecoveryOrderingTests {
    @Test func enablingAndErasingWaitForARunningRecovery() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        SlowRecoveryPlugin.log.reset()
        let host = env.makeHost([SlowRecoveryPlugin.self])
        host.beginRecoveries()
        await host.setEnabled(true, for: "slowrecovery")
        #expect(SlowRecoveryPlugin.log.events == ["recovered", "activated"])
        SlowRecoveryPlugin.log.reset()
        host.retryDeferredRecoveries()
        try await host.eraseData(for: "slowrecovery")
        #expect(SlowRecoveryPlugin.log.events.first != "erased")
    }
}

nonisolated final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func add(_ event: String) { lock.withLock { _events.append(event) } }
    func reset() { lock.withLock { _events = [] } }
}

final class SlowRecoveryPlugin: LintelPlugin {
    nonisolated static let log = OrderLog()
    static let manifest = PluginManifest(id: "slowrecovery", displayName: "Slow", symbolName: "clock", order: 90)
    init(context: PluginContext) {}
    nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome {
        try? await Task.sleep(for: .milliseconds(150))
        log.add("recovered")
        return .deferred
    }
    func activate() async throws { Self.log.add("activated") }
    func eraseData() async throws { Self.log.add("erased") }
}

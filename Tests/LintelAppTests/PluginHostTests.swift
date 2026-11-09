import AppKit
import Foundation
import LintelCore
import LintelKit
import Synchronization
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
        env.recoveryScript.reset([.done])
        let host = env.makeHost([LaunchRecoveryPlugin.self])

        await host.start()
        await host.waitForRecoveries()
        await host.start()
        await host.waitForRecoveries()

        #expect(host.state(of: "launchrecovery").map(isDisabled) == true)
        #expect(env.recoveryScript.callCount == 1)
        #expect(host.recoveryOutcomes["launchrecovery"] == .done)
    }

    @Test func deferredRecoveryIsRetriedOnRequestUntilDone() async {
        defer { env.tearDown() }
        env.recoveryScript.reset([.deferred, .done])
        let host = env.makeHost([LaunchRecoveryPlugin.self])

        await host.start()
        await host.waitForRecoveries()
        #expect(host.recoveryOutcomes["launchrecovery"] == .deferred)

        host.retryDeferredRecoveries()
        await host.waitForRecoveries()
        #expect(host.recoveryOutcomes["launchrecovery"] == .done)

        host.retryDeferredRecoveries()
        await host.waitForRecoveries()
        #expect(env.recoveryScript.callCount == 2)
    }

    @MainActor
    @Test func appActivationRetriesADeferredRecovery() async {
        defer { env.tearDown() }
        env.recoveryScript.reset([.deferred, .done])
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
        #expect(env.recoveryScript.callCount == 2)
    }

    @Test func recoveryBoundGivesDeferredWithoutWaitingForHungWork() async {
        // On a clock whose bound has passed as soon as it is awaited, hung work (here: work that never ends until
        // it is let go) is not waited for.
        let hung = Gate()
        let outcome = await withDeadline(.seconds(1), clock: ExpiredClock()) {
            await hung.wait()
            return RecoveryOutcome.done
        }
        #expect(outcome == nil)
        hung.open()
    }

    @Test func aRetryNeverStartsASecondRecoveryBesideOneThatIsStillRunning() async {
        defer { env.tearDown() }
        let host = env.makeHost([OverrunRecoveryPlugin.self], recoveryBudget: .seconds(1), clock: ExpiredClock())
        await host.start()
        await host.waitForRecoveries()
        #expect(host.recoveryOutcomes["overrunrecovery"] == .deferred)
        // The first call is past its bound but still running: the retries wait for it, they do not overlap it.
        host.retryDeferredRecoveries()
        host.retryDeferredRecoveries()
        await host.waitForRecoveries()
        #expect(env.overrun.entered.withLock { $0 } == 1)
    }

    @Test func aStuckActivationFailsTheStartAndDoesNotHoldUpAQuit() async {
        defer { env.tearDown() }
        // The activation budget is over as soon as it is awaited; the activation itself waits for its gate.
        let host = env.makeHost([StuckActivationPlugin.self], activationBudget: .seconds(1), clock: ExpiredClock())
        await host.setEnabled(true, for: "stuckactivation")
        guard case .failed(let error)? = host.state(of: "stuckactivation") else {
            Issue.record("the stuck activation should fail the plugin")
            return
        }
        #expect(error as? PluginHostError == .activationTimedOut)
        // A quit goes through the same queue: it returns instead of waiting behind the stuck start.
        await host.stop()
        #expect(host.state(of: "stuckactivation").map(isDisabled) != false)
        env.environment.services.value(
            StuckActivationGateKey.self, for: env.environment.makeContext(for: StuckActivationPlugin.manifest)
        ).open()
    }

    @Test func quittingTearsTheirServicesDown() async {
        defer { env.tearDown() }
        let host = env.makeHost([LaunchRecoveryPlugin.self])
        await host.start()
        await host.waitForRecoveries()
        let services = env.environment.services
        #expect(services.holds(RecoveryScriptKey.self, pluginID: "launchrecovery"))
        await host.stop()
        #expect(!services.holds(RecoveryScriptKey.self, pluginID: "launchrecovery"))
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
        // Time moves only when the test says so. Each source reports when it has answered, so the clock is moved
        // only after the two that answer have, and then times out exactly the stuck one.
        let clock = GatedClock()
        let alphaDone = Gate()
        let throwingDone = Gate()
        let stuckGate = env.environment.services.value(
            StuckGateKey.self, for: env.environment.makeContext(for: StuckPlugin.manifest))
        let sources = [
            RegisteredSource(
                pluginID: "alpha", source: SignallingSource(base: InstantSource(id: "alpha.instant"), done: alphaDone)),
            RegisteredSource(pluginID: "stuck", source: StuckSource(gate: stuckGate)),
            RegisteredSource(pluginID: "stuck", source: SignallingSource(base: ThrowingSource(), done: throwingDone)),
        ]
        let run = Task {
            await SourceRunner.run(
                sources, query: NormalizedQuery(raw: "Te", normalized: "te"), limit: 10, budget: .seconds(1),
                clock: clock)
        }
        await alphaDone.wait()
        await throwingDone.wait()
        // Only the stuck source can still be waiting on its deadline: move time until that one fires.
        let advancer = Task {
            while await clock.waitForSleepers(atLeast: 1) { clock.advance(.seconds(1)) }
        }
        let results = await run.value
        clock.finish()
        await advancer.value

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
        let context = env.environment.makeContext(for: SlowRecoveryPlugin.manifest)
        let order = env.environment.services.value(RecoveryOrderKey.self, for: context)
        let host = env.makeHost([SlowRecoveryPlugin.self])
        // The recovery cannot answer until the gate opens; a start or an erase that did not wait for it would log
        // "before recovery".
        host.beginRecoveries()
        let enabling = Task { await host.setEnabled(true, for: "slowrecovery") }
        order.gate.open()
        await enabling.value
        #expect(order.log.events == ["recovered", "activated after recovery"])

        order.log.reset()
        host.retryDeferredRecoveries()
        try await host.eraseData(for: "slowrecovery")
        #expect(order.log.events == ["recovered", "erased", "activated after recovery"])
    }
}

nonisolated final class OrderLog: Sendable {
    private let lock = Mutex<[String]>([])
    var events: [String] { lock.withLock { $0 } }
    func add(_ event: String) { lock.withLock { $0.append(event) } }
    func reset() { lock.withLock { $0 = [] } }
}

/// What `SlowRecoveryPlugin` records, per app instance (a plugin service), and the gate that holds its recovery.
nonisolated final class RecoveryOrder: Sendable {
    let log = OrderLog()
    let gate = Gate()
    let finished = Mutex(false)
}

nonisolated enum RecoveryOrderKey: PluginServiceKey {
    static func make(context: PluginContext) -> RecoveryOrder { RecoveryOrder() }
}

final class SlowRecoveryPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "slowrecovery", displayName: "Slow", symbolName: "clock", order: 90)
    private let order: RecoveryOrder

    init(context: PluginContext) {
        order = context.services.value(RecoveryOrderKey.self, for: context)
    }

    nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome {
        let order = context.services.value(RecoveryOrderKey.self, for: context)
        await order.gate.wait()
        order.log.add("recovered")
        order.finished.withLock { $0 = true }
        return .deferred
    }

    func activate() async throws {
        order.log.add(order.finished.withLock { $0 } ? "activated after recovery" : "activated before recovery")
    }

    func eraseData() async throws { order.log.add("erased") }
}

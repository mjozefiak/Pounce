import Foundation
import PounceKit
import Testing

@testable import PounceApp

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

        // The stuck source blocks for 2 s; the query returns at its 100 ms budget.
        #expect(elapsed < .seconds(1))
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

    private func isDisabled(_ state: PluginState) -> Bool {
        if case .disabled = state { return true }
        return false
    }
}

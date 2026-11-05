import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// What the status test plugins report; only touched on the main actor.
@MainActor
enum StatusBox {
    static var status: SettingsStatus?
    static var reads = 0

    static func reset() {
        status = nil
        reads = 0
    }
}

/// Reports `StatusBox.status` and needs the microphone.
final class BannerStatusPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "banner", displayName: "Status", symbolName: "s.circle", order: 6)

    init(context: PluginContext) {}

    var requiredPermissions: Set<Permission> { [.microphone] }
    var settingsStatus: SettingsStatus? {
        StatusBox.reads += 1
        return StatusBox.status
    }
}

/// Fails to activate `StatusBox.failuresLeft` times, then starts.
final class RecoveringPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "recovering", displayName: "Recovering", symbolName: "r.circle", order: 7)

    /// How many more activations throw; set by `PluginHostTests` only.
    @MainActor static var failuresLeft = 0

    init(context: PluginContext) {}

    func activate() async throws {
        LifecycleLog.shared.record("recovering.activate")
        if Self.failuresLeft > 0 {
            Self.failuresLeft -= 1
            throw TestError.activationFailed
        }
    }
}

/// Lets the observation callback of `SettingsHostModel` run.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

/// Spec `2026-11-04-lintel-main-window`, step 2.2: the one banner and when it is read again.
@MainActor
@Suite(.serialized) struct SettingsHostTests {
    let env: TestEnvironment

    init() throws {
        env = try TestEnvironment()
        StatusBox.reset()
    }

    private func model(
        _ host: PluginHost, reader: FakePermissionsReader = FakePermissionsReader(),
        navigation: SettingsHostModel.Navigation = SettingsHostModel.Navigation()
    ) -> SettingsHostModel {
        SettingsHostModel(host: host, reader: reader, navigation: navigation)
    }

    @Test func aShellPaneHasNoBanner() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        let model = model(host)
        model.show("general")
        #expect(model.banner == nil)
    }

    @Test func thePaneAppearingReadsThePluginsStatus() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        StatusBox.status = SettingsStatus(level: .ok, title: "Ready")
        let model = model(host)
        model.show("banner")
        #expect(model.banner?.level == .ok)
        #expect(model.banner?.title == "Ready")
    }

    @Test func aStateChangeReadsTheBannerAgain() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        StatusBox.status = SettingsStatus(level: .ok, title: "Ready")
        let model = model(host)
        model.show("banner")

        await host.setEnabled(false, for: "banner")
        await settle()
        #expect(model.banner?.level == .neutral)
        #expect(model.banner?.actions.map(ActionKind.init) == [.enablePlugin])

        await host.setEnabled(true, for: "banner")
        await settle()
        #expect(model.banner?.level == .ok)
    }

    @Test func resultsChangedFromThePanesPluginReadsTheBannerAgain() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        let model = model(host)
        model.show("banner")
        #expect(model.banner == nil)

        StatusBox.status = SettingsStatus(level: .attention, title: "1 thing to do")
        model.pluginResultsChanged("alpha")
        #expect(model.banner == nil)
        model.pluginResultsChanged("banner")
        #expect(model.banner?.title == "1 thing to do")
    }

    @Test func theRelayForwardsThePluginID() {
        let relay = PluginStatusRelay()
        var received: [String] = []
        relay.handler = { received.append($0) }
        relay.signal("banner")
        #expect(received == ["banner"])
    }

    @Test func aFinishedPluginActionReadsTheBannerAgain() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        let fix = SettingsStatusAction(
            title: "Start Indexing",
            destination: .plugin(id: "start") {
                StatusBox.status = SettingsStatus(level: .ok, title: "Indexing")
            })
        StatusBox.status = SettingsStatus(level: .attention, title: "Indexing hasn't started", fix: [fix])
        let model = model(host)
        model.show("banner")
        #expect(model.banner?.level == .attention)

        await model.perform(fix)
        #expect(model.banner?.title == "Indexing")
        #expect(model.isBusy == false)
    }

    @Test func navigationActionsGoThroughTheShell() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        var models: [String?] = []
        var urls: [URL] = []
        var navigation = SettingsHostModel.Navigation()
        navigation.openModels = { id, packageID in
            #expect(id == "banner")
            models.append(packageID)
        }
        navigation.openURL = { urls.append($0) }
        let model = model(host, navigation: navigation)
        model.show("banner")

        await model.perform(SettingsStatusAction(title: "Get It", destination: .models(packageID: "parakeet")))
        await model.perform(SettingsStatusAction(title: "Open", destination: .systemSettings(.microphone)))
        #expect(models == ["parakeet"])
        #expect(urls == [Permission.microphone.settingsURL])
    }

    @Test func aDeniedMicrophoneShowsAttentionAndAppActivationReadsItAgain() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        let reader = FakePermissionsReader()
        reader.answers[.microphone] = .denied
        let model = model(host, reader: reader)
        model.show("banner")
        #expect(model.banner?.level == .attention)

        reader.answers[.microphone] = .granted
        model.refresh()  // what app activation calls
        #expect(model.banner == nil)
    }

    @Test func anInactivePluginsStatusIsNeverRead() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        await host.setEnabled(false, for: "banner")
        StatusBox.reads = 0
        let model = model(host)
        model.show("banner")
        #expect(model.banner?.level == .neutral)
        #expect(StatusBox.reads == 0)
    }
}

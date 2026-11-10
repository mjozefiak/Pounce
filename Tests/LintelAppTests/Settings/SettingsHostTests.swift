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

/// Fails to activate once and does not touch the shared `LifecycleLog` or `RecoveringPlugin.failuresLeft`: the settings
/// suite runs in parallel with the serialized `PluginHostTests`, which assert on both (a shared log or counter made
/// `PluginHostTests` fail whenever the two suites overlapped).
final class FailingOncePlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "recovering", displayName: "Recovering", symbolName: "r.circle", order: 7)

    init(context: PluginContext) {}

    func activate() async throws { throw TestError.activationFailed }
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

    /// Step 6.5a: Permissions and Models get a sidebar dot from the banner the shell derives for them; an ok
    /// shell banner gives none.
    @Test func shellPanesGetADotFromTheirDerivedBanner() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        let attention = StatusDerivation.Banner(level: .attention, title: "1 model is needed", detail: nil, actions: [])
        let ready = StatusDerivation.Banner(level: .ok, title: "Ready", detail: nil, actions: [])
        let model = SettingsHostModel(
            host: host, reader: FakePermissionsReader(),
            shellBanners: ["models": { attention }, "permissions": { attention }, "general": { ready }])
        let items = Dictionary(uniqueKeysWithValues: model.sections.flatMap(\.items).map { ($0.id, $0) })
        #expect(items["models"]?.attention == .attention)
        #expect(items["permissions"]?.attention == .attention)
        #expect(items["general"]?.needsAttention == false)
        #expect(items["advanced"]?.needsAttention == false)
    }

    /// Step 6.5a (prototype `set-off`): the pane of an inactive plugin is dimmed under its banner.
    @Test func anInactivePaneIsDimmed() {
        #expect(SettingsHost.bodyOpacity(isActive: true) == 1)
        #expect(SettingsHost.bodyOpacity(isActive: false) == 0.5)
    }

    /// Review of PR #52: the dimmed pane of an inactive plugin cannot be used, so its controls never open the
    /// plugin's stores (Dictation's history switch) or skip a confirmation (Meetings' shorter retention).
    @Test func anInactivePaneIsNotInteractive() throws {
        #expect(SettingsHost.bodyIsInteractive(isActive: true))
        #expect(!SettingsHost.bodyIsInteractive(isActive: false))
        let source = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/LintelApp/Settings/Host/SettingsHost.swift"), encoding: .utf8)
        #expect(source.contains(".disabled(!Self.bodyIsInteractive(isActive: entry?.isActive ?? true))"))
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
        #expect(model.banner?.level == .ok)

        StatusBox.status = SettingsStatus(level: .attention, title: "1 thing to do")
        model.pluginResultsChanged("alpha")
        #expect(model.banner?.level == .ok)
        model.pluginResultsChanged("banner")
        #expect(model.banner?.title == "1 thing to do")
    }

    @Test func theRelayForwardsThePluginID() async {
        let gate = RelayGate()
        let relay = PluginStatusRelay(wait: { await gate.wait() })
        let received = ReceivedIDs()
        relay.handler = { received.ids.append($0) }
        relay.signal("banner")
        await gate.waitForWaiters(1)
        gate.open()
        #expect(await received.eventually(["banner"]))
    }

    /// Step 4.4 review fix: a burst of signals from one plugin reaches the banner once per merge window.
    @Test func theRelayMergesABurstPerPlugin() async {
        let gate = RelayGate()
        let relay = PluginStatusRelay(wait: { await gate.wait() })
        let received = ReceivedIDs()
        relay.handler = { received.ids.append($0) }
        relay.signal("clipboard")
        relay.signal("clipboard")
        relay.signal("files")
        relay.signal("clipboard")
        await gate.waitForWaiters(2)
        #expect(received.ids.isEmpty)
        #expect(gate.waiters == 2)
        gate.open()
        #expect(await received.eventually(["clipboard", "files"]))
        // The next signal after the window is forwarded again.
        relay.signal("clipboard")
        await gate.waitForWaiters(1)
        gate.open()
        #expect(await received.eventually(["clipboard", "clipboard", "files"]))
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
        #expect(model.banner?.level == .ok)
    }

    @Test func aDeniedPermissionGivesTheSidebarDotThoughThePluginSaysNothing() async {
        defer { env.tearDown() }
        let host = env.makeHost([BannerStatusPlugin.self])
        await host.start()
        let reader = FakePermissionsReader()
        reader.answers[.microphone] = .denied
        let model = model(host, reader: reader)
        #expect(StatusBox.status == nil)
        #expect(model.attention["banner"] == .attention)

        reader.answers[.microphone] = .granted
        model.refresh()
        #expect(model.attention["banner"] == nil)
    }

    @Test func aFailedPluginGivesAnErrorDot() async {
        defer { env.tearDown() }
        let host = env.makeHost([FailingOncePlugin.self])
        await host.start()
        let model = model(host)
        #expect(model.attention["recovering"] == .error)
        model.show("recovering")
        #expect(model.banner?.level == .error)
    }

    @Test func theSidebarAndThePaneFollowTurnOn() async throws {
        defer { env.tearDown() }
        let host = env.makeHost([PanePlugin.self])
        await host.start()
        let model = model(host)
        model.show("pane")
        let row = { model.sections.flatMap(\.items).first { $0.id == "pane" } }
        #expect(try #require(row()).isActive == false)
        #expect(model.plugins.first { $0.id == "pane" }?.isActive == false)

        let turnOn = try #require(model.banner?.actions.first)
        await model.perform(turnOn)
        #expect(try #require(row()).isActive)
        #expect(model.plugins.first { $0.id == "pane" }?.isActive == true)

        // A Features switch changes the host state only; the observation builds the panes again.
        await host.setEnabled(false, for: "pane")
        await settle()
        #expect(try #require(row()).isActive == false)
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

/// The merge window of `PluginStatusRelay`, opened by the test.
@MainActor final class RelayGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waiters: Int { continuations.count }

    func wait() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitForWaiters(_ count: Int) async {
        for _ in 0..<1000 where continuations.count < count {
            await Task.yield()
        }
    }

    func open() {
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume() }
    }
}

/// The plugin ids the relay forwarded.
@MainActor final class ReceivedIDs {
    var ids: [String] = []

    /// Whether `ids`, sorted, becomes `expected` within a few yields.
    func eventually(_ expected: [String]) async -> Bool {
        for _ in 0..<1000 where ids.sorted() != expected {
            await Task.yield()
        }
        return ids.sorted() == expected
    }
}

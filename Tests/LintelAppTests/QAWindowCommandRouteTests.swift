#if DEBUG
import Foundation
import LintelKit
import Testing

@testable import LintelApp
@testable import WindowsPlugin

/// Phase 0, step 0.6 of window management v2: the QA command route reaches the plugin's real dispatcher
/// (`PluginCommand.run`, the closure a shortcut calls) with the real engine over the fake window client, on isolated
/// data. Nothing here touches a real window, a real Accessibility permission or the user's defaults.
@MainActor @Suite struct QAWindowCommandRouteTests {
    private struct Rig {
        let environment: TestEnvironment
        let plugin: WindowsPlugin
        let route: QACommandRoute
        let file: URL
    }

    private func rig() async throws -> Rig {
        let test = try TestEnvironment()
        var environment = test.environment
        environment.accessibility = .granted
        // One display, as on the owner's Mac: a switch then hides the windows of the old workspace.
        environment.windowClient = QAWindowClient(displays: [QAWindowClient.displays[0]])
        // The host creates the plugin's folder; without it the journal cannot be written and nothing is parked.
        try FileManager.default.createDirectory(
            at: environment.storageDirectory(for: WindowsPlugin.manifest.id), withIntermediateDirectories: true)
        let plugin = WindowsPlugin(
            context: environment.makeContext(for: WindowsPlugin.manifest), hud: NullHUD(),
            activationCenter: NotificationCenter())
        try await plugin.activate()
        let file = FileManager.default.temporaryDirectory.appending(path: "qa-window-route-\(UUID().uuidString).txt")
        let route = QACommandRoute(
            file: file, commands: { plugin.commands }, qaPlugin: { $0 == "windows" ? plugin : nil })
        return Rig(environment: test, plugin: plugin, route: route, file: file)
    }

    private func tearDown(_ rig: Rig) async {
        await rig.plugin.deactivate()
        rig.environment.tearDown()
    }

    @Test func aSwitchThenAMoveThroughTheRouteMovesNothingAndTheStateSaysSo() async throws {
        let rig = try await rig()
        #expect(await rig.route.run("windows.workspace.2") == "ok")
        await rig.plugin.runtime?.settle()
        #expect(await rig.route.run("windows.moveToWorkspace.3") == "ok")
        await rig.plugin.runtime?.settle()
        let state = await rig.route.run("qa windows state")
        // All five fake windows are parked on workspace 1 and none moved to workspace 3. The fake system still names
        // the first window as focused (a parked window keeps the app's focus); it is hidden, so it was refused.
        #expect(state.hasPrefix("ok: current=2 "), "\(state)")
        #expect(state.contains("ws1=90000.9000,90001.9001,90002.9002,90003.9003,90004.9004"), "\(state)")
        #expect(!state.contains("ws3="), "\(state)")
        #expect(state.contains("parked=5"), "\(state)")
        // Back on workspace 1 the focus returns to a window of it.
        #expect(await rig.route.run("windows.workspace.1") == "ok")
        await rig.plugin.runtime?.settle()
        let back = await rig.route.run("qa windows state")
        #expect(back.hasPrefix("ok: current=1 focused=900"), "\(back)")
        await tearDown(rig)
    }

    @Test func aMoveOfTheFocusedWindowGoesThroughTheRouteToo() async throws {
        let rig = try await rig()
        #expect(await rig.route.run("windows.moveToWorkspace.3") == "ok")
        await rig.plugin.runtime?.settle()
        let state = await rig.route.run("qa windows state")
        #expect(state.contains("ws3=90000.9000"), "\(state)")
        #expect(state.contains("ws1=90001.9001,90002.9002,90003.9003,90004.9004"), "\(state)")
        // The state line carries numbers only: no title and no bundle id.
        #expect(!state.contains("Fake") && !state.contains("qa.fake"))
        await tearDown(rig)
    }
}
#endif

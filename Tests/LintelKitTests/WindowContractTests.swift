import CoreGraphics
import Foundation
import LintelKit
import Testing

/// Window management, step 1.2: the additive contract has defaults, so a plugin that ignores it compiles and
/// sees an empty, unsupported window system.
@Suite struct WindowContractTests {
    private func makeContext() -> PluginContext { TestContext.make() }

    @Test func defaultContextReportsNoWindowsAndNoDisplays() async {
        let windows = makeContext().windows
        #expect(await windows.windows().isEmpty)
        #expect(await windows.displays().isEmpty)
        #expect(await windows.focusedWindow() == nil)
        #expect(windows.processStart(of: 1) == nil)
        guard case .unsupported = windows.availability else {
            Issue.record("the default client must be unsupported")
            return
        }
        var iterator = windows.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func defaultClientRefusesToMoveAnything() async {
        let client = NoWindowClient()
        let id = WindowID(pid: 1, number: 2)
        await #expect(throws: WindowClientError.windowGone) {
            try await client.setFrame(.zero, for: id)
        }
        await #expect(throws: WindowClientError.windowGone) { try await client.focus(id) }
    }

    @Test func displayOrientationFollowsTheShape() {
        let landscape = DisplayInfo(id: 1, uuid: "A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let portrait = DisplayInfo(id: 2, uuid: "B", frame: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        #expect(landscape.orientation == .landscape)
        #expect(portrait.orientation == .portrait)
        #expect(landscape.visibleFrame == landscape.frame)
    }

    @Test func windowIDsOrderByProcessThenNumber() {
        let ids = [WindowID(pid: 2, number: 1), WindowID(pid: 1, number: 9), WindowID(pid: 1, number: 3)]
        #expect(
            ids.sorted() == [WindowID(pid: 1, number: 3), WindowID(pid: 1, number: 9), WindowID(pid: 2, number: 1)])
    }

    @Test func aPluginWithoutRecoveryHasTheDefault() async {
        #expect(await PlainPlugin.recoverAtLaunch(context: makeContext()) == .done)
    }
}

@MainActor
private final class PlainPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "plain", displayName: "Plain", symbolName: "circle", order: 1)
    init(context: PluginContext) {}
}

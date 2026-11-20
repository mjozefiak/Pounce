import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// What the plugins say is in progress (`LintelPlugin.busyReason`), mutable from the tests.
@MainActor final class BusyScript {
    static let shared = BusyScript()
    var reasons: [String: BusyReason] = [:]
}

@MainActor final class BusyOnePlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "busy-one", displayName: "One", symbolName: "1.circle", order: 1)
    init(context: PluginContext) {}
    var busyReason: BusyReason? { BusyScript.shared.reasons["busy-one"] }
}

@MainActor final class BusyTwoPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "busy-two", displayName: "Two", symbolName: "2.circle", order: 2)
    init(context: PluginContext) {}
    var busyReason: BusyReason? { BusyScript.shared.reasons["busy-two"] }
}

@MainActor final class BusyFailingPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "busy-failing", displayName: "Failing", symbolName: "3.circle", order: 3)
    init(context: PluginContext) {}
    struct Boom: Error {}
    func activate() async throws { throw Boom() }
    var busyReason: BusyReason? { BusyScript.shared.reasons["busy-failing"] }
}

@MainActor final class BusyOffPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "busy-off", displayName: "Off", symbolName: "4.circle", order: 4, defaultEnabled: false)
    init(context: PluginContext) {}
    var busyReason: BusyReason? { BusyScript.shared.reasons["busy-off"] }
}

@Suite(.serialized) @MainActor struct BusyReasonTests {
    let env: TestEnvironment

    init() throws {
        env = try TestEnvironment()
        BusyScript.shared.reasons = [:]
    }

    private func host() async -> PluginHost {
        let host = env.makeHost([
            NoFilesPlugin.self, BusyOnePlugin.self, BusyTwoPlugin.self, BusyFailingPlugin.self, BusyOffPlugin.self,
        ])
        await host.start()
        return host
    }

    @Test func nothingBusyGivesNil() async {
        defer { env.tearDown() }
        #expect(await host().busyReason == nil)
    }

    @Test func anActivePluginsReasonIsReported() async {
        defer { env.tearDown() }
        let host = await host()
        BusyScript.shared.reasons["busy-two"] = .processing
        #expect(host.busyReason == .processing)
    }

    @Test func recordingWinsOverProcessingWhateverTheOrder() async {
        defer { env.tearDown() }
        let host = await host()
        BusyScript.shared.reasons = ["busy-one": .processing, "busy-two": .recording]
        #expect(host.busyReason == .recording)
        BusyScript.shared.reasons = ["busy-one": .recording, "busy-two": .processing]
        #expect(host.busyReason == .recording)
    }

    @Test func aFailedOrDisabledPluginIsNotAsked() async {
        defer { env.tearDown() }
        let host = await host()
        #expect(host.state(of: "busy-failing")?.isActive == false)
        #expect(host.state(of: "busy-off")?.isActive == false)
        BusyScript.shared.reasons = ["busy-failing": .recording, "busy-off": .recording]
        #expect(host.busyReason == nil)
    }
}

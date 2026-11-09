import Foundation
import LintelKit
import Testing

@testable import LintelApp

@MainActor
final class OpenedFiles {
    static let shared = OpenedFiles()
    var claimed: [String] = []
}

final class ClaimingPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "claimer", displayName: "Claimer", symbolName: "c.circle", order: 1)
    init(context: PluginContext) {}
    func handleOpenedFile(_ url: URL) async -> Bool {
        guard url.pathExtension == "claimed" else { return false }
        OpenedFiles.shared.claimed.append("claimer:" + url.lastPathComponent)
        return true
    }
}

final class SecondClaimingPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "second", displayName: "Second", symbolName: "s.circle", order: 2)
    init(context: PluginContext) {}
    func handleOpenedFile(_ url: URL) async -> Bool {
        OpenedFiles.shared.claimed.append("second:" + url.lastPathComponent)
        return true
    }
}

final class NoFilesPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "nofiles", displayName: "Plain", symbolName: "p.circle", order: 0)
    init(context: PluginContext) {}
}

/// A file opened with Lintel goes to the first plugin that takes it (step 4.4, the `.lintellayouts` open handler).
@Suite(.serialized) struct OpenFileRoutingTests {
    @Test func theFileGoesToTheFirstPluginThatTakesItAndOthersAreNotAsked() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        OpenedFiles.shared.claimed = []
        let host = env.makeHost([NoFilesPlugin.self, ClaimingPlugin.self, SecondClaimingPlugin.self])
        let taken = await host.openFile(URL(fileURLWithPath: "/tmp/a.claimed"))
        #expect(taken)
        #expect(OpenedFiles.shared.claimed == ["claimer:a.claimed"])
    }

    @Test func aFileNobodyWantsIsReportedAndPluginsWithoutTheHookTakeNothing() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        OpenedFiles.shared.claimed = []
        #expect(await env.makeHost([NoFilesPlugin.self]).openFile(URL(fileURLWithPath: "/tmp/a.txt")) == false)
        #expect(await env.makeHost([ClaimingPlugin.self]).openFile(URL(fileURLWithPath: "/tmp/a.txt")) == false)
        #expect(OpenedFiles.shared.claimed.isEmpty)
    }

    @Test func theRegisteredPluginsTakeOnlyTheLayoutsFileType() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = env.makeHost(PluginRegistry.all)
        #expect(await host.openFile(URL(fileURLWithPath: "/tmp/notes.txt")) == false)
        #expect(await host.openFile(URL(fileURLWithPath: "/tmp/notes.json")) == false)
    }
}

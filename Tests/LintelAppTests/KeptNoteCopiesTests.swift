import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// A stand-in for Notes: answers how many copies it keeps of an owner's recordings and records its deletions.
final class KeptCopiesStandInPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "keptnotes", displayName: "KeptNotes", symbolName: "note", order: 9)
    init(context: PluginContext) {}

    func keptNoteCopyCount(ofOwner owner: PluginID) async -> Int { owner == "storage" ? 3 : 0 }
    func deleteKeptNoteCopies(ofOwner owner: PluginID, ownerErased: Bool) async -> Bool {
        LifecycleLog.shared.record("copies.delete.\(owner.rawValue).erased=\(ownerErased)")
        return owner != "unerasable"
    }
}

/// Owner decision L1-39: "Also delete kept copies" removes copies in Notes only when the user ticked it and only
/// after the owner's own erase succeeded. An extension of `PluginHostTests`, so it shares that suite's serialization
/// (the test plugins share `LifecycleLog`).
extension PluginHostTests {
    @MainActor
    @Test func theCountComesFromThePluginsThatKeepCopies() async {
        defer { env.tearDown() }
        let host = env.makeHost([StorageWritingPlugin.self, KeptCopiesStandInPlugin.self])
        await host.start()
        let controls = FeatureControls(host: host) {}
        #expect(await controls.keptNoteCopies(of: "storage") == 3)
        #expect(await controls.keptNoteCopies(of: "alpha") == 0)
    }

    @MainActor
    @Test func eraseWithoutTheBoxNeverTouchesTheCopies() async {
        defer { env.tearDown() }
        let host = env.makeHost([StorageWritingPlugin.self, KeptCopiesStandInPlugin.self])
        await host.start()
        let controls = FeatureControls(host: host) {}
        #expect(await controls.erase("storage") == nil)
        #expect(await controls.erase("storage", alsoDeleteKeptCopies: false) == nil)
        #expect(!LifecycleLog.shared.events.contains { $0.hasPrefix("copies.delete") })
    }

    @MainActor
    @Test func eraseWithTheBoxDeletesTheCopiesAfterTheOwnerErased() async throws {
        defer { env.tearDown() }
        let host = env.makeHost([StorageWritingPlugin.self, KeptCopiesStandInPlugin.self])
        await host.start()
        let controls = FeatureControls(host: host) {}
        #expect(await controls.erase("storage", alsoDeleteKeptCopies: true) == nil)
        let events = LifecycleLog.shared.events
        let erased = try #require(events.firstIndex(of: "storage.erase"))
        let copies = try #require(events.firstIndex(of: "copies.delete.storage.erased=true"))
        #expect(erased < copies, "the owner is erased first, the copies after")
    }

    @MainActor
    @Test func aFailedEraseLeavesTheCopiesAlone() async {
        defer { env.tearDown() }
        let host = env.makeHost([UnerasablePlugin.self, KeptCopiesStandInPlugin.self])
        await host.start()
        let controls = FeatureControls(host: host) {}
        let message = await controls.erase("unerasable", alsoDeleteKeptCopies: true)
        #expect(message?.isEmpty == false)
        #expect(!LifecycleLog.shared.events.contains { $0.hasPrefix("copies.delete") })
    }
}

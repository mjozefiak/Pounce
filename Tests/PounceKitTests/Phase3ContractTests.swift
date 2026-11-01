import Foundation
import Testing

@testable import PounceKit

/// A plugin written against the Phase 2 contract: it must still compile and show no status line.
@MainActor final class PhaseTwoPlugin: PouncePlugin {
    static let manifest = PluginManifest(id: "phase2", displayName: "Phase 2", symbolName: "2.circle", order: 1)
    init(context: PluginContext) {}
}

@Suite @MainActor struct SearchStatusContractTests {
    @Test func defaultIsEmpty() {
        let plugin = PhaseTwoPlugin(context: TestContext.make())
        #expect(plugin.searchStatus.isEmpty)
    }

    @Test func statusDefaultsToANoticeWithoutActions() {
        let status = SearchStatus(id: "x", symbolName: "hand.raised", message: "Message")
        #expect(status.style == .notice)
        #expect(status.actions.isEmpty)
        let action = SearchStatusAction(id: "open", title: "Open", kind: .openSettings)
        guard case .openSettings = action.kind else {
            Issue.record("unexpected kind")
            return
        }
    }
}

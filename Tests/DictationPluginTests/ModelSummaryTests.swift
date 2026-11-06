import Foundation
import LintelUI
import Testing

@testable import DictationPlugin

/// Spec `2026-11-04-lintel-main-window`, step 3.3: the pane's one-line model summary and its link to Models.
@MainActor
@Suite struct DictationModelSummaryTests {
    @Test func theSummaryNamesTheModelAndItsState() {
        #expect(
            ModelChoiceRow.summary(title: "Parakeet Ultra", state: .notInstalled) == "Parakeet Ultra · not installed")
        #expect(ModelChoiceRow.actionTitle(for: .notInstalled) == "Get it in Models")
        #expect(ModelChoiceRow.actionTitle(for: .installed) == "Manage in Models")
    }
}

/// The view types a `body` value holds, found by reflection: the branch an `if` took is stored as a value, the
/// other one is not, so this lists what the pane draws.
enum ViewTree {
    static func typeNames(in value: Any) -> Set<String> {
        var names: Set<String> = []
        collect(value, into: &names, depth: 0)
        return names
    }

    private static func collect(_ value: Any, into names: inout Set<String>, depth: Int) {
        guard depth < 60 else { return }
        let type = String(describing: Swift.type(of: value))
        names.insert(type.components(separatedBy: "<").first ?? type)
        for child in Mirror(reflecting: value).children {
            collect(child.value, into: &names, depth: depth + 1)
        }
    }
}

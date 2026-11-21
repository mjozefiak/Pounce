#if DEBUG
import Testing

@testable import DictationPlugin

@Suite @MainActor struct DictationHUDQATests {
    @Test func everyStateNameIsUniqueAndResolves() {
        let names = DictationHUDQA.states.map(\.name)
        #expect(Set(names).count == names.count)
        for name in names { #expect(DictationHUDQA.state(named: name) != nil) }
        #expect(DictationHUDQA.state(named: "no-such-state") == nil)
    }

    @Test func theListCoversTheStatesOfTheHUD() {
        let states = DictationHUDQA.states.map(\.state)
        #expect(states.contains(.allowMicrophone))
        #expect(states.contains(.finishing))
        #expect(states.contains(.pasted))
        #expect(states.contains(.pastedUnformatted(all: true)))
        #expect(states.contains(.pastedUnformatted(all: false)))
        #expect(states.contains(.problem(.nothingToPaste)))
        #expect(states.contains(.problem(.speechModelBusy)))
        let recordings = states.filter { if case .recording = $0 { true } else { false } }
        #expect(recordings.count == 3)
        // Every state has its words; none is blank.
        for state in states { #expect(!state.title.isEmpty) }
    }

    @Test func thePanelHasTheIdentifierTheShellLooksFor() {
        #expect(DictationHUDQA.panelIdentifier == "lintel.qa.hud")
        #expect(DictationHUDQA.settingName == "qaHUD")
    }
}
#endif

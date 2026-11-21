#if DEBUG
import Testing

@testable import MeetingsPlugin

@Suite @MainActor struct MeetingHUDQATests {
    @Test func everyStateNameIsUniqueAndResolves() {
        let names = MeetingHUDQA.states.map(\.name)
        #expect(Set(names).count == names.count)
        for name in names { #expect(MeetingHUDQA.state(named: name) != nil) }
        #expect(MeetingHUDQA.state(named: "no-such-state") == nil)
    }

    @Test func theListCoversEveryScreenAndEveryNotice() {
        let states = MeetingHUDQA.states.map(\.state)
        let screens = Set(states.map(MeetingHUDPanel.screen))
        #expect(screens.contains("allowMicrophone") && screens.contains("recording"))
        #expect(screens.contains("finishing") && screens.contains("processing"))
        #expect(screens.contains("saved") && screens.contains("savedIncomplete"))
        let problems = states.compactMap { state -> MeetingHUDState.Problem? in
            if case .problem(let problem) = state { problem } else { nil }
        }
        #expect(problems.count == 12)
        var notices: [MeetingHUDState.Notice] = []
        for case .recording(let recording) in states { if let notice = recording.notice { notices.append(notice) } }
        #expect(notices.count == 10)
        for state in states { #expect(!state.title.isEmpty) }
    }

    @Test func thePanelHasTheIdentifierTheShellLooksFor() {
        #expect(MeetingHUDQA.panelIdentifier == "lintel.qa.hud")
        #expect(MeetingHUDQA.settingName == "qaHUD")
    }

    @Test func theQAProviderBinaryIsReadFromTheSettingOnly() throws {
        let harness = try MeetingsHarness(settings: [
            "plugins.meetings.qaProviderBinary": .string("/opt/lintel-qa/bin/claude")
        ])
        #expect(harness.meetingsSettings.qaProviderBinary?.path == "/opt/lintel-qa/bin/claude")
        let none = try MeetingsHarness()
        #expect(none.meetingsSettings.qaProviderBinary == nil)
    }
}
#endif

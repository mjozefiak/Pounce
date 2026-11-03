import Foundation
import Testing

@testable import MeetingsPlugin

@Suite struct MeetingHUDStateTests {
    private func recording(_ change: (inout MeetingHUDState.Recording) -> Void = { _ in }) -> MeetingHUDState {
        var recording = MeetingHUDState.Recording()
        change(&recording)
        return .recording(recording)
    }

    @Test func aPlainRecordingHasNoSecondLineAndOnlyTheStopButton() {
        let state = recording()
        #expect(state.detail == nil)
        #expect(!state.hasDetailLine)
        #expect(state.actions == [.stop])
        #expect(state.title(for: .stop) == "End recording")
        #expect(state.isRecording && state.showsMeters)
        #expect(state.hidesAfter == nil)
    }

    @Test func noticesFollowTheirPriority() {
        var value = MeetingHUDState.Recording()
        value.showsConsent = true
        #expect(value.notice == .consent)
        value.loadingModel = true
        #expect(value.notice == .loadingModel)
        value.modelUnavailable = false
        #expect(value.notice == .modelUnavailable(busy: false))
        value.secondsLeft = 300
        #expect(value.notice == .limitCountdown(300))
        value.noSystemAudio = true
        #expect(value.notice == .noSystemAudio)
        value.lost = [.mic]
        #expect(value.notice == .deviceDisconnected)
        value.writeProblem = true
        #expect(value.notice == .writeProblem)
        value.lowDisk = true
        #expect(value.notice == .lowDisk)
    }

    @Test func aTrackThatIsOffNeverRaisesItsOwnNotice() {
        var value = MeetingHUDState.Recording()
        value.recordsMicrophone = false
        value.unavailable = [.mic]
        #expect(value.notice == nil)
        value.recordsSystem = false
        value.noSystemAudio = true
        #expect(value.notice == nil)
    }

    @Test func aSystemTrackThatCouldNotStartPointsToThePermission() {
        var value = MeetingHUDState.Recording()
        value.unavailable = [.system]
        #expect(value.notice == .noSystemAudio)
        #expect(MeetingHUDState.recording(value).actions == [.openSettings, .stop])
    }

    @Test func theTextsAreTheSpecsStates() {
        #expect(MeetingHUDState.problem(.nothingHeard).title == "Nothing heard")
        #expect(MeetingHUDState.processing(.recognisingSpeakers).title == "Processing: recognising speakers…")
        #expect(MeetingHUDState.processing(.transcribing(remaining: 3)).title == "Processing: transcribing (3 left)")
        #expect(MeetingHUDState.problem(.modelMissing).title == "Download a speech model in Settings")
        #expect(MeetingHUDState.problem(.modelMissing).actions == [.openSettings])
        #expect(recording { $0.secondsLeft = 125 }.detail == "Recording ends in 2:05")
    }

    @Test func clockFormatsMinutesAndHours() {
        #expect(MeetingHUDState.clock(0) == "0:00")
        #expect(MeetingHUDState.clock(65) == "1:05")
        #expect(MeetingHUDState.clock(3_600) == "1:00:00")
        #expect(MeetingHUDState.clock(10_199) == "2:49:59")
        #expect(MeetingHUDState.clock(-4) == "0:00")
    }

    @Test func messagesHideThemselvesAndLiveStatesDoNot() {
        #expect(MeetingHUDState.saved.hidesAfter == .seconds(3))
        #expect(MeetingHUDState.problem(.nothingHeard).hidesAfter != nil)
        #expect(MeetingHUDState.problem(.microphoneDenied(offersSystemOnly: true)).hidesAfter == .seconds(20))
        #expect(MeetingHUDState.finishing.hidesAfter == nil)
        #expect(MeetingHUDState.processing(.closing).hidesAfter == nil)
        #expect(MeetingHUDState.allowMicrophone.hidesAfter == nil)
    }

    @Test func theAccessibilityLabelCarriesStateTimeAndNotice() {
        let state = recording {
            $0.elapsedSeconds = 125
            $0.lowDisk = true
        }
        let label = state.accessibilityLabel
        #expect(label.hasPrefix("Recording a meeting. 2:05."))
        #expect(label.contains("Low disk space"))
        #expect(MeetingHUDState.saved.accessibilityLabel == "Meeting saved")
    }

    @Test func announcementsAreMadeOncePerHUDSession() {
        var gate = MeetingAnnouncementGate()
        let start = recording()
        #expect(gate.announce(start) == "Meeting recording started")
        // The pill refreshes every second and on every level; VoiceOver stays quiet.
        #expect(gate.announce(recording { $0.elapsedSeconds = 1 }) == nil)
        #expect(gate.announce(recording { $0.micLevel = 0.9 }) == nil)
        #expect(gate.announce(recording { $0.secondsLeft = 60 }) == nil)
        #expect(gate.announce(recording { $0.lowDisk = true }) != nil)
        #expect(gate.announce(recording { $0.lowDisk = true }) == nil)
        #expect(gate.announce(.finishing) == "Meeting recording stopped")
        #expect(gate.announce(.processing(.closing)) == nil)
        #expect(gate.announce(.saved) == "Meeting saved")
        gate.reset()
        #expect(gate.announce(start) == "Meeting recording started")
    }

    @Test func theConsentAndLoadingNoticesAreNotAnnouncedAsProblems() {
        #expect(recording { $0.showsConsent = true }.announcement == "Meeting recording started")
        #expect(recording { $0.loadingModel = true }.announcement == "Meeting recording started")
    }
}

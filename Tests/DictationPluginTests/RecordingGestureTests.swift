import Testing

@testable import DictationPlugin
@testable import LintelSpeech

private final class FakeClock: @unchecked Sendable {
    private(set) var instant = ContinuousClock.now
    func advance(_ duration: Duration) { instant += duration }
}

@Suite struct RecordingGestureTests {
    private func gesture(_ clock: FakeClock, in state: String) -> RecordingGesture {
        var gesture = RecordingGesture(now: { clock.instant })
        switch state {
        case "pressed": _ = gesture.handle(.keyDown)
        case "toggle":
            _ = gesture.handle(.keyDown)
            clock.advance(.milliseconds(100))
            _ = gesture.handle(.keyUp)
        case "stopPressed":
            _ = gesture.handle(.keyDown)
            clock.advance(.milliseconds(100))
            _ = gesture.handle(.keyUp)
            _ = gesture.handle(.keyDown)
        case "finishing":
            _ = gesture.handle(.menu)
            _ = gesture.handle(.menu)
        default: break
        }
        return gesture
    }

    private func name(_ state: RecordingGesture.State) -> String {
        switch state {
        case .idle: "idle"
        case .pressed: "pressed"
        case .toggle: "toggle"
        case .stopPressed: "stopPressed"
        case .finishing: "finishing"
        }
    }

    /// The whole table of the spec: state × event → (state, action).
    @Test(
        arguments: [
            ("idle", RecordingGesture.Event.keyDown, "pressed", RecordingGesture.Action.start),
            ("idle", .keyUp, "idle", .none),
            ("idle", .menu, "toggle", .start),
            ("idle", .cancel, "idle", .none),
            ("pressed", .keyDown, "pressed", .none),
            ("pressed", .menu, "finishing", .finish),
            ("pressed", .cancel, "idle", .cancel),
            ("toggle", .keyDown, "stopPressed", .none),
            ("toggle", .keyUp, "toggle", .none),
            ("toggle", .menu, "finishing", .finish),
            ("toggle", .cancel, "idle", .cancel),
            ("stopPressed", .keyDown, "stopPressed", .none),
            ("stopPressed", .keyUp, "finishing", .finish),
            ("stopPressed", .menu, "finishing", .finish),
            ("stopPressed", .cancel, "idle", .cancel),
            ("finishing", .keyDown, "finishing", .none),
            ("finishing", .keyUp, "finishing", .none),
            ("finishing", .menu, "finishing", .none),
            ("finishing", .cancel, "finishing", .none),
        ])
    func everyCellOfTheTable(
        from: String, event: RecordingGesture.Event, to: String, action: RecordingGesture.Action
    ) {
        var gesture = gesture(FakeClock(), in: from)
        #expect(name(gesture.state) == from)
        #expect(gesture.handle(event) == action)
        #expect(name(gesture.state) == to)
    }

    @Test func aTapKeepsRecordingAndASecondPressEndsItAtKeyUp() {
        let clock = FakeClock()
        var gesture = RecordingGesture(now: { clock.instant })
        #expect(gesture.handle(.keyDown) == .start)
        clock.advance(.milliseconds(120))
        #expect(gesture.handle(.keyUp) == .none)
        #expect(gesture.isRecording)
        clock.advance(.seconds(30))
        #expect(gesture.handle(.keyDown) == .none)
        #expect(gesture.isRecording)
        #expect(gesture.handle(.keyUp) == .finish)
        #expect(!gesture.isRecording)
    }

    @Test func holdingIsPushToTalk() {
        let clock = FakeClock()
        var gesture = RecordingGesture(now: { clock.instant })
        #expect(gesture.handle(.keyDown) == .start)
        // Autorepeat key-downs while held change nothing.
        for _ in 0..<5 {
            clock.advance(.milliseconds(80))
            #expect(gesture.handle(.keyDown) == .none)
        }
        #expect(gesture.handle(.keyUp) == .finish)
    }

    @Test func theThresholdIsThreeHundredMilliseconds() {
        let clock = FakeClock()
        var tap = RecordingGesture(now: { clock.instant })
        _ = tap.handle(.keyDown)
        clock.advance(.milliseconds(299))
        #expect(tap.handle(.keyUp) == .none)

        var hold = RecordingGesture(now: { clock.instant })
        _ = hold.handle(.keyDown)
        clock.advance(.milliseconds(300))
        #expect(hold.handle(.keyUp) == .finish)
    }

    @Test func cancellingDuringAPressIgnoresTheLateKeyUp() {
        var gesture = RecordingGesture()
        _ = gesture.handle(.keyDown)
        #expect(gesture.handle(.cancel) == .cancel)
        #expect(gesture.handle(.keyUp) == .none)
        #expect(gesture.state == .idle)
    }

    @Test func aNewRecordingNeedsTheTextToBeDone() {
        var gesture = RecordingGesture()
        _ = gesture.handle(.menu)
        _ = gesture.handle(.menu)
        #expect(gesture.handle(.keyDown) == .none)
        gesture.finished()
        #expect(gesture.handle(.keyDown) == .start)
    }
}

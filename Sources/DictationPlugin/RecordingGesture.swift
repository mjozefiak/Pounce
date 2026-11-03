import Foundation

/// The shortcut's tap and hold, as a pure state machine (spec: `RecordingGesture`).
///
/// - A short press starts recording and the key-up keeps it running ("toggle"); the next press ends it, at
///   its key-up, so releasing the key never lands in a new session.
/// - A press held for the hold threshold or longer is push-to-talk: the key-up ends it.
/// - The menu command starts a toggle recording (the menu has no key-up) and ends any recording.
/// - Escape or the HUD's ✕ cancels, except while the text is already being produced.
struct RecordingGesture {
    enum State: Equatable {
        case idle
        /// The shortcut is down since this instant.
        case pressed(since: ContinuousClock.Instant)
        /// Recording continues after a tap.
        case toggle
        /// The second press of a toggle is down; its key-up ends the recording.
        case stopPressed
        /// Recording ended; the text is being produced and pasted.
        case finishing
    }

    enum Event: Equatable {
        case keyDown
        case keyUp
        case menu
        case cancel
    }

    /// What the session has to do about an event.
    enum Action: Equatable {
        case none
        case start
        case finish
        case cancel
    }

    /// A press shorter than this is a tap.
    static let holdThreshold: Duration = .milliseconds(300)

    private(set) var state = State.idle
    private let now: () -> ContinuousClock.Instant

    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    var isRecording: Bool {
        switch state {
        case .pressed, .toggle, .stopPressed: true
        case .idle, .finishing: false
        }
    }

    mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .keyDown):
            state = .pressed(since: now())
            return .start
        case (.idle, .menu):
            state = .toggle
            return .start
        case (.idle, _):
            return .none

        case (.pressed, .keyDown):
            // Autorepeat while held.
            return .none
        case (.pressed(let since), .keyUp):
            if now() - since < Self.holdThreshold {
                state = .toggle
                return .none
            }
            state = .finishing
            return .finish
        case (.pressed, .menu), (.toggle, .menu), (.stopPressed, .menu):
            state = .finishing
            return .finish
        case (.pressed, .cancel), (.toggle, .cancel), (.stopPressed, .cancel):
            state = .idle
            return .cancel

        case (.toggle, .keyDown):
            state = .stopPressed
            return .none
        case (.toggle, .keyUp):
            return .none

        case (.stopPressed, .keyDown):
            return .none
        case (.stopPressed, .keyUp):
            state = .finishing
            return .finish

        case (.finishing, _):
            return .none
        }
    }

    /// The text was pasted (or the session failed): a new recording may start.
    mutating func finished() {
        state = .idle
    }
}

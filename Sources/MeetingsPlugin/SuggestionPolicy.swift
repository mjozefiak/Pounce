import Foundation

/// An app Pounce suggests a recording for.
struct KnownMeetingApp: Equatable, Sendable {
    let bundleID: String
    let name: String

    /// Zoom, Teams, Slack, FaceTime, Webex, Discord. Browsers are not here on purpose: a web page using the
    /// microphone gives false alarms, so a browser counts only when the user adds it.
    static let all: [KnownMeetingApp] = [
        KnownMeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
        KnownMeetingApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        KnownMeetingApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams"),
        KnownMeetingApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        KnownMeetingApp(bundleID: "com.apple.FaceTime", name: "FaceTime"),
        KnownMeetingApp(bundleID: "Cisco-Systems.Spark", name: "Webex"),
        KnownMeetingApp(bundleID: "com.webex.meetingmanager", name: "Webex"),
        KnownMeetingApp(bundleID: "com.hnc.Discord", name: "Discord"),
    ]

    static func name(of bundleID: String) -> String? { all.first { $0.bundleID == bundleID }?.name }
}

/// What the policy needs from the settings at the moment it decides. Read fresh each time, so a change in
/// Settings applies at once.
struct SuggestionConfig: Equatable, Sendable {
    var enabled = false
    var mutedBundleIDs: Set<String> = []
    var extraBundleIDs: [String] = []
    /// Pounce's own bundle ID: dictation and recording a meeting never trigger a suggestion.
    var ownBundleID: String?

    /// The listed app (known or added by the user) that `bundleID` belongs to, or `nil`. A helper process
    /// (`com.google.Chrome.helper` for `com.google.Chrome`) belongs to its app. Pounce itself never matches.
    func listedApp(for bundleID: String) -> String? {
        if let own = ownBundleID, Self.belongs(bundleID, to: own) { return nil }
        let candidates = KnownMeetingApp.all.map(\.bundleID) + extraBundleIDs
        // The longest match wins, so `com.microsoft.teams2.helper` is Teams 2, not an app called `…teams`.
        return candidates.filter { Self.belongs(bundleID, to: $0) }.max { $0.count < $1.count }
    }

    private static func belongs(_ bundleID: String, to app: String) -> Bool {
        bundleID == app || bundleID.hasPrefix(app + ".")
    }
}

/// The pure state machine behind meeting suggestions (spec: Wykrywanie spotkań, Faza 3). It sees events and
/// the time (a `Duration` from the detector's clock) and answers with effects; it starts and stops nothing.
///
/// A suggestion is made only when all of these hold: suggestions are enabled; the app is listed (known, or
/// added by the user; browsers only when added); the app has used the input without a break for at least
/// `inputThreshold`; Pounce is not recording or finishing; the app is not muted; and it is the first time in
/// this mic-use session of that app. After a recording that started from a suggestion, when the app stops
/// using the microphone and both tracks have been quiet for `quietThreshold`, it asks whether to stop.
struct SuggestionPolicy: Sendable {
    static let inputThreshold: Duration = .seconds(10)
    static let quietThreshold: Duration = .seconds(60)
    /// A track louder than this counts as sound for the end-of-meeting question (the level is 0...1).
    static let soundLevel: Float = 0.01

    enum Effect: Equatable, Sendable {
        /// Offer to record `bundleID` (the listed app's ID).
        case suggest(bundleID: String)
        /// The meeting seems to be over: ask whether to stop the recording that started from `bundleID`.
        case askToEnd(bundleID: String)
    }

    private struct Use {
        var processes: Set<UInt32> = []
        /// Start of the current mic-use session; `nil` while no process of the app uses the input.
        var since: Duration?
        /// The 10 s mark of this session has been reached (a suggestion was made, or refused).
        var decided = false
    }

    private struct Recording {
        var source: String
        var lastSound: Duration
        var asked = false
    }

    private var uses: [String: Use] = [:]
    /// Which listed app a process belongs to, so that its "stopped" event (which carries no bundle ID) is
    /// attributed correctly.
    private var appOfProcess: [UInt32: String] = [:]
    private var recording: Recording?

    // MARK: Input

    mutating func handle(_ event: ProcessAudioEvent, now: Duration, config: SuggestionConfig) {
        if event.isRunningInput {
            guard let bundleID = event.bundleID, let app = config.listedApp(for: bundleID) else { return }
            appOfProcess[event.processObjectID] = app
            var use = uses[app] ?? Use()
            if use.processes.isEmpty {
                use.since = now
                use.decided = false
            }
            use.processes.insert(event.processObjectID)
            uses[app] = use
        } else {
            guard let app = appOfProcess.removeValue(forKey: event.processObjectID), var use = uses[app] else {
                return
            }
            use.processes.remove(event.processObjectID)
            if use.processes.isEmpty {
                use.since = nil
                use.decided = false
            }
            uses[app] = use
        }
    }

    /// A recording that started from a suggestion for `source` begins (`nil`: started any other way, which
    /// is never asked about).
    mutating func recordingStarted(source: String?, now: Duration) {
        guard let source else {
            recording = nil
            return
        }
        recording = Recording(source: source, lastSound: now)
    }

    mutating func recordingLevel(_ level: Float, now: Duration) {
        guard level > Self.soundLevel, recording != nil else { return }
        recording?.lastSound = now
    }

    mutating func recordingEnded() { recording = nil }

    /// Forgets everything (the detector stopped listening).
    mutating func reset() {
        uses = [:]
        appOfProcess = [:]
        recording = nil
    }

    // MARK: Decisions

    /// What to do now. `isBusy`: Pounce records a meeting or is still finishing one.
    mutating func evaluate(now: Duration, config: SuggestionConfig, isBusy: Bool) -> [Effect] {
        var effects: [Effect] = []
        for (app, use) in uses.sorted(by: { $0.key < $1.key }) {
            guard let since = use.since, !use.decided, now - since >= Self.inputThreshold else { continue }
            uses[app]?.decided = true
            guard config.enabled, !isBusy, !config.mutedBundleIDs.contains(app) else { continue }
            effects.append(.suggest(bundleID: app))
        }
        if let recording, !recording.asked, config.enabled,
            uses[recording.source]?.processes.isEmpty ?? true,
            now - recording.lastSound >= Self.quietThreshold
        {
            self.recording?.asked = true
            effects.append(.askToEnd(bundleID: recording.source))
        }
        return effects
    }

    /// The next moment after `now` at which `evaluate` can have something to say, or `nil` when only an event
    /// can change that. A moment that has passed without effect (the setting is off) is not asked for again.
    func nextWake(after now: Duration) -> Duration? {
        var wakes: [Duration] = []
        for use in uses.values {
            if let since = use.since, !use.decided { wakes.append(since + Self.inputThreshold) }
        }
        if let recording, !recording.asked, uses[recording.source]?.processes.isEmpty ?? true {
            wakes.append(recording.lastSound + Self.quietThreshold)
        }
        return wakes.filter { $0 > now }.min()
    }
}

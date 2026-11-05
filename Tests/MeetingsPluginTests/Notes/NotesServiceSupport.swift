import Foundation
import LintelKit
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// Polls a condition on the main actor; the notes jobs run in the background.
@MainActor
func waitFor(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// The notes service over a real (temporary, encrypted) library, a scripted model and an in-memory keychain.
@MainActor
final class NotesServiceRig {
    static let gibibyte: UInt64 = 1 << 30

    let harness: MeetingsHarness
    let library: MeetingsLibrary
    let settings: MeetingsSettings
    let llm: ScriptedLLM
    let lease = LLMLease(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    let file = Shared<URL?>(URL(filePath: "/models/llm/notes-test.gguf"))
    /// The packages `openModels` was called with.
    let modelsOpened = Shared<[String?]>([])
    let changes = Shared(0)
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var service: NotesService!

    var store: MeetingsStore { library.store! }

    init(
        settings initial: [String: SettingValue] = ["plugins.meetings.notesEnabled": .bool(true)],
        physicalMemory: UInt64 = 16 * NotesServiceRig.gibibyte,
        handler: @escaping ScriptedLLM.Handler = NotesFake.standard,
        runtime custom: (any LLMRuntime)? = nil, shutdownLimit: Duration = .milliseconds(200),
        configure: @escaping @Sendable (inout NotesPipeline.Configuration) -> Void = { _ in }
    ) throws {
        harness = try MeetingsHarness(settings: initial)
        library = harness.library()
        settings = MeetingsSettings(harness.context.settings, physicalMemory: physicalMemory)
        llm = ScriptedLLM(handler: handler)
        library.open()
        let llm = llm
        let file = file
        let opened = modelsOpened
        let changes = changes
        let now = fixedNow
        service = NotesService(
            NotesService.Dependencies(
                library: library, settings: settings, lease: lease, modelFile: { _ in file.get() },
                makeRuntime: { custom ?? llm },
                configure: { configuration in
                    configuration.busyPoll = .milliseconds(10)
                    configure(&configuration)
                }, now: { now }, shutdownLimit: shutdownLimit,
                openModels: { id in opened.update { $0.append(id) } }, changed: { changes.update { $0 += 1 } }))
        library.onMeetingReady = { [service] id in service?.meetingBecameReady(id) }
        library.onWillClose = { [service] in service?.cancelJobs() }
    }

    /// A `ready` meeting with this transcript (one speaker per name).
    @discardableResult
    func addMeeting(_ utterances: [NotesUtterance] = NotesFixtures.meeting(), status: MeetingStatus = .ready) throws
        -> Int64
    {
        let id = try store.insertMeeting(
            uuid: UUID().uuidString, startedAt: Date(timeIntervalSince1970: 1_700_000_000), speechModelID: "m",
            status: status)
        var speakers: [String: Int64] = [:]
        for utterance in utterances {
            if speakers[utterance.speaker] == nil {
                speakers[utterance.speaker] = try store.insertSpeaker(
                    meetingID: id, label: utterance.speaker, isSelf: false, channel: .system)
            }
            try store.insertSegment(
                meetingID: id, channel: .system, startMs: utterance.startMs, endMs: utterance.startMs + 2_000,
                text: utterance.text, speakerID: speakers[utterance.speaker])
        }
        return id
    }

    func speakerID(of meetingID: Int64, named name: String) throws -> Int64 {
        let document = try #require(try store.loadDocument(id: meetingID))
        return try #require(document.speakers.first { $0.label == name }).id
    }

    func start() async { await service.start() }

    /// Until no job is queued or running.
    func settle() async -> Bool {
        await waitFor { !self.service.isBusy }
    }

    func record(_ id: Int64) throws -> NotesRecord { try #require(try store.notesRecord(of: id)) }

    func document(_ id: Int64) throws -> MeetingDocument { try #require(try store.loadDocument(id: id)) }
}

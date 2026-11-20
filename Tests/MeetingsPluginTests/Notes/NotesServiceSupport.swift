import Foundation
import LintelKit
import LintelSpeech
import LintelTestSupport
import Synchronization
import Testing

@testable import MeetingsPlugin

/// For a condition with no event to hang on (a model's own state, a fake's flag): polls on the main actor with the
/// shared 60 s guard and an `Issue` at the caller's line. A rig's service state has events: use `NotesServiceRig.wait`.
@MainActor
func waitFor(
    _ what: String = "the condition to hold", sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    await pollUntil(what, sourceLocation: sourceLocation) { condition() }
}

/// The meeting ids a library reports through `onMeetingReady`, as events instead of a polled list.
final class ReadyEvents: Sendable {
    private let continuation: AsyncStream<Int64>.Continuation
    private let stream: AsyncStream<Int64>
    private let seen = Mutex<[Int64]>([])

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Int64.self, bufferingPolicy: .unbounded)
    }

    /// Every id told so far.
    var all: [Int64] { seen.withLock { $0 } }

    /// The callback to install as `onMeetingReady`.
    func tell(_ id: Int64) {
        seen.withLock { $0.append(id) }
        continuation.yield(id)
    }

    /// The next id told, as soon as it is. `nil` when the task is cancelled or `hangGuard` passes; the guard
    /// only ends a test whose event never comes. One wait per instance after a `nil`: cancelling the wait ends
    /// the stream for good, so a later `next` returns `nil` at once (#165).
    func next(hangGuard: Duration = .seconds(60)) async -> Int64? {
        await withTaskGroup(of: Int64?.self) { group in
            group.addTask { [stream] in
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: hangGuard)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
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
    /// Rung whenever the service reports a change (`Dependencies.changed`): a phase, a finished job, the switch.
    let bell = ChangeBell()
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
        let bell = bell
        let now = fixedNow
        service = NotesService(
            NotesService.Dependencies(
                library: library, settings: settings, lease: lease, modelFile: { _ in file.get() },
                makeRuntime: { custom ?? llm },
                configure: { configuration in
                    configuration.busyPoll = .milliseconds(10)
                    configure(&configuration)
                }, now: { now }, shutdownLimit: shutdownLimit,
                openModels: { id in opened.update { $0.append(id) } },
                changed: {
                    changes.update { $0 += 1 }
                    bell.ring()
                }))
        library.onMeetingReady = { [service] id in service?.meetingBecameReady(id) }
        library.onWillClose = { [service] in service?.cancelJobs() }
    }

    /// A `ready` meeting with this transcript (one speaker per name). Written off the main actor: every commit is
    /// durable, and on the one main thread that all `@MainActor` tests share those waits starve the service's own
    /// main-actor work (#165, #178).
    @discardableResult
    func addMeeting(_ utterances: [NotesUtterance] = NotesFixtures.meeting(), status: MeetingStatus = .ready)
        async throws -> Int64
    {
        try await Self.seed(store, utterances: utterances, status: status)
    }

    private nonisolated static func seed(_ store: MeetingsStore, utterances: [NotesUtterance], status: MeetingStatus)
        async throws -> Int64
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

    /// A write to the store (a rename, notes text) off the main actor, for the same reason as `addMeeting`.
    func perform<T: Sendable>(_ body: @escaping @Sendable (MeetingsStore) throws -> T) async throws -> T {
        try await Self.run(store, body)
    }

    private nonisolated static func run<T: Sendable>(
        _ store: MeetingsStore, _ body: @Sendable (MeetingsStore) throws -> T
    ) async throws -> T {
        try body(store)
    }

    func speakerID(of meetingID: Int64, named name: String) throws -> Int64 {
        let document = try #require(try store.loadDocument(id: meetingID))
        return try #require(document.speakers.first { $0.label == name }).id
    }

    func start() async { await service.start() }

    /// Until `condition` holds, looked at again after every change the service reports; 60 s guard, the `Issue`
    /// lands on the caller's line.
    func wait(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, until condition: @MainActor () -> Bool
    ) async -> Bool {
        await bell.wait(guard: .seconds(60), what, sourceLocation: sourceLocation) { condition() }
    }

    /// Until no job is queued or running.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await wait("the notes jobs to finish", sourceLocation: sourceLocation) { !self.service.isBusy }
    }

    func record(_ id: Int64) throws -> NotesRecord { try #require(try store.notesRecord(of: id)) }

    func document(_ id: Int64) throws -> MeetingDocument { try #require(try store.loadDocument(id: id)) }
}

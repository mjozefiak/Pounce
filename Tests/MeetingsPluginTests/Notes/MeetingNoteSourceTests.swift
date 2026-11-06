import Foundation
import LintelCore
import LintelKit
import Testing

@testable import MeetingsPlugin

private func query(_ text: String) -> NormalizedQuery {
    NormalizedQuery(raw: text, normalized: text.lowercased())
}

/// The five meetings of `LibraryRig` read through the Notes source.
@MainActor
struct NoteSourceRig {
    let rig: LibraryRig
    let hub = NoteChangeHub()
    let board = NotesBoard()
    let regenerated = Shared<[Int64]>([])
    let source: MeetingNoteSource

    var store: MeetingsStore {
        get throws { try rig.store }
    }

    init() throws {
        rig = try LibraryRig()
        let regenerated = regenerated
        let hub = hub
        source = MeetingNoteSource(
            library: rig.library, board: board, hub: hub,
            regenerate: { id in regenerated.update { $0.append(id) } }, openNotesModel: {},
            appName: { $0 == "us.zoom.xos" ? "Zoom" : nil }, changed: { hub.notify() })
    }

    func key(_ name: String) throws -> NoteKey {
        let id = try #require(rig.ids[name])
        let uuid = try store.meetingUUID(id: id)
        return NoteKey(pluginID: "meetings", id: try #require(uuid))
    }

    func name(of key: NoteKey) -> String? {
        rig.ids.first { (try? store.meetingUUID(id: $0.value)) == key.id }?.key
    }
}

@MainActor
@Suite("MeetingNoteSource: reading")
struct MeetingNoteSourceReadingTests {
    @Test("list has the library's order and the same rows as the list mode's All filter")
    func parityWithListMode() async throws {
        let rig = try NoteSourceRig()
        let page = try await rig.source.list(matching: nil, after: nil, limit: 100)
        let mode = try await rig.rig.search("", filter: .all)
        #expect(
            page.items.map(\.id.id)
                == mode.map { MeetingLibraryPresentation.meetingID($0.itemKey) }.compactMap { id in
                    try? rig.store.meetingUUID(id: id ?? -1)
                })
        #expect(page.total == 5)
        #expect(page.next == nil)
        #expect(page.items.map(\.kind).allSatisfy { $0 == .meeting })
        #expect(rig.name(of: page.items[0].id) == "notes")
    }

    @Test("a query finds the same meetings as the list mode and reports where it matched")
    func queryParity() async throws {
        let rig = try NoteSourceRig()
        for text in ["roadmapa", "budżet", "budzet zatwierdzony", "dzień", "nic takiego", "retro"] {
            let page = try await rig.source.list(matching: query(text), after: nil, limit: 100)
            let mode = try await rig.rig.search(text)
            #expect(page.items.count == mode.count, "\(text)")
            #expect(Set(page.items.compactMap { rig.name(of: $0.id) }) == Set(rig.rig.keys(mode)), "\(text)")
        }
        let page = try await rig.source.list(matching: query("roadmapa"), after: nil, limit: 10)
        let item = try #require(page.items.first)
        #expect(item.matches.map(\.layerID) == ["transcript"])
        #expect(item.matches.first?.snippet.contains("Roadmapa") == true)
        #expect(!item.titleMatched)
        let titled = try await rig.source.list(matching: query("planning"), after: nil, limit: 10)
        #expect(titled.items.first?.titleMatched == true)
        #expect(titled.items.first?.matches.isEmpty == true)
    }

    @Test("a cursor continues where the page ended, with the total of the whole query")
    func paging() async throws {
        let rig = try NoteSourceRig()
        let first = try await rig.source.list(matching: nil, after: nil, limit: 2)
        #expect(first.items.count == 2)
        #expect(first.total == 5)
        let cursor = try #require(first.next)
        let second = try await rig.source.list(matching: nil, after: cursor, limit: 2)
        let secondNext = try #require(second.next)
        let third = try await rig.source.list(matching: nil, after: secondNext, limit: 2)
        #expect(third.next == nil)
        let all = (first.items + second.items + third.items).map(\.id)
        #expect(all.count == 5)
        #expect(Set(all).count == 5)
        let whole = try await rig.source.list(matching: nil, after: nil, limit: 100)
        #expect(all == whole.items.map(\.id))
        await #expect(throws: MeetingNoteSourceError.invalidArgument) {
            _ = try await rig.source.list(matching: nil, after: NoteCursor(token: "x"), limit: 2)
        }
    }

    @Test("content has the notes and the transcript layers, the speakers and the details")
    func content() async throws {
        let rig = try NoteSourceRig()
        let content = try #require(try await rig.source.content(for: rig.key("notes")))
        #expect(content.layers.map(\.id) == ["notes", "transcript"])
        #expect(content.layers.map(\.author) == [.agent, .stt])
        #expect(content.layers[0].markdown == "## Decyzje\n\n- Budżet zatwierdzony")
        #expect(content.layers[1].markdown == "Dzień dobry wszystkim")
        #expect(content.summary.title == "Planning budżetu")
        #expect(content.summary.sourceApp == "Zoom")
        #expect(content.summary.durationMs == 3_900_000)
        #expect(content.summary.state == .ready)
        let speaker = try speakerID(rig, "notes")
        #expect(content.speakers == [NoteSpeaker(id: String(speaker), name: "Anna")])
        #expect(!content.details.isEmpty)
        let plain = try #require(try await rig.source.content(for: rig.key("incomplete")))
        #expect(plain.layers.isEmpty)
        #expect(plain.summary.state == .interrupted)
    }

    @Test("an unknown meeting is nil, not an error; a key of another plugin or an empty one is refused")
    func absence() async throws {
        let rig = try NoteSourceRig()
        let gone = NoteKey(pluginID: "meetings", id: UUID().uuidString.lowercased())
        #expect(try await rig.source.content(for: gone) == nil)
        #expect(try await rig.source.exists([gone, rig.key("plain")]) == [try rig.key("plain")])
        await #expect(throws: MeetingNoteSourceError.invalidArgument) {
            _ = try await rig.source.content(for: NoteKey(pluginID: "dictation", id: "1/2"))
        }
    }

    @Test("exists answers a large batch")
    func largeBatch() async throws {
        let rig = try NoteSourceRig()
        let known = try rig.key("plain")
        let keys = (0..<900).map { _ in NoteKey(pluginID: "meetings", id: UUID().uuidString.lowercased()) } + [known]
        #expect(try await rig.source.exists(keys) == [known])
    }

    @Test("every read throws while the library is not open, and none reports a note as gone")
    func closedStore() async throws {
        let rig = try NoteSourceRig()
        let key = try rig.key("plain")
        rig.rig.library.close()
        await #expect(throws: MeetingNoteSourceError.storeUnavailable) {
            _ = try await rig.source.list(matching: nil, after: nil, limit: 10)
        }
        await #expect(throws: MeetingNoteSourceError.storeUnavailable) { _ = try await rig.source.exists([key]) }
        await #expect(throws: MeetingNoteSourceError.storeUnavailable) { _ = try await rig.source.content(for: key) }
        #expect(rig.source.actions(for: key).isEmpty)
    }

    private func speakerID(_ rig: NoteSourceRig, _ name: String) throws -> Int64 {
        let meeting = try #require(rig.rig.ids[name])
        return try #require(try rig.store.speakers(meetingID: meeting).first).id
    }
}

@MainActor
@Suite("MeetingNoteSource: the keychain and the switch")
struct MeetingNoteSourceAvailabilityTests {
    @Test("a locked Keychain and a plugin that is off both make every read throw, and nothing is deleted")
    func lockedAndOff() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        let source = try #require(plugin.noteSources.first)
        let key = NoteKey(pluginID: "meetings", id: "x")
        // Not activated: the library is closed.
        await #expect(throws: (any Error).self) { _ = try await source.exists([key]) }
        harness.keychain.failReads(with: .interactionNotAllowed)
        try await plugin.activate()
        await #expect(throws: (any Error).self) { _ = try await source.exists([key]) }
        await #expect(throws: (any Error).self) { _ = try await source.content(for: key) }
        await #expect(throws: (any Error).self) { _ = try await source.list(matching: nil, after: nil, limit: 5) }
        #expect(harness.keychain.deleteCount == 0)
        await plugin.deactivate()
    }

    @Test("an open library answers, and switching the plugin off ends the change streams")
    func openAndDeactivate() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        try await plugin.activate()
        let source = try #require(plugin.noteSources.first)
        #expect(try await source.list(matching: nil, after: nil, limit: 5).items.isEmpty)
        #expect(try await source.exists([NoteKey(pluginID: "meetings", id: "x")]).isEmpty)
        var iterator = source.makeChanges().makeAsyncIterator()
        await plugin.deactivate()
        #expect(await iterator.next() == nil)
        await #expect(throws: (any Error).self) { _ = try await source.exists([]) }
    }
}

@Suite("MeetingNoteSource: state mapping")
struct MeetingNoteStateTests {
    private static let rows: [(MeetingStatus, NotesStatus, NotesJobPhase?, Bool, NoteState)] = [
        (.recording, .ok, nil, false, .recording),
        (.processing, .running, nil, false, .processing),
        (.incomplete, .ok, nil, false, .interrupted),
        (.failed, .ok, nil, false, .failed),
        (.ready, .none, nil, false, .ready),
        (.ready, .ok, nil, false, .ready),
        (.ready, .partial, nil, false, .partial),
        (.ready, .stale, nil, false, .stale),
        (.ready, .running, nil, false, .writing(done: 0, of: 0)),
        (.ready, .running, .mapping(done: 2, total: 8), false, .writing(done: 2, of: 8)),
        (.ready, .failed, nil, false, .failed),
        (.ready, .none, nil, true, .needsModel),
        (.ready, .ok, nil, true, .ready),
    ]

    @Test("one row of the mapping each", arguments: rows)
    func mapping(row: (MeetingStatus, NotesStatus, NotesJobPhase?, Bool, NoteState)) {
        #expect(
            MeetingNoteMapping.state(status: row.0, notesStatus: row.1, phase: row.2, needsModel: row.3) == row.4)
    }

    @MainActor
    @Test("the source reports the mapped state of a stored meeting")
    func throughTheSource() async throws {
        let rig = try NoteSourceRig()
        let expected: [String: NoteState] = [
            "notes": .ready, "stale": .stale, "plain": .ready, "incomplete": .interrupted, "failed": .failed,
        ]
        let page = try await rig.source.list(matching: nil, after: nil, limit: 10)
        for item in page.items {
            #expect(item.state == expected[try #require(rig.name(of: item.id))])
        }
        let id = try #require(rig.rig.ids["plain"])
        rig.board.update {
            $0.enabled = true
            $0.modelMissing = true
            $0.awaitingModel = [id]
        }
        let waiting = try #require(try await rig.source.content(for: rig.key("plain")))
        #expect(waiting.summary.state == .needsModel)
        rig.board.update { $0.phases[id] = .mapping(done: 1, total: 3) }
        let writing = try #require(try await rig.source.content(for: rig.key("plain")))
        #expect(writing.summary.state == .writing(done: 1, of: 3))
    }
}

@MainActor
@Suite("MeetingNoteSource: layers")
struct MeetingNoteLayerTests {
    private func document(segments: [MeetingDocument.Segment], notes: String? = nil) -> MeetingDocument {
        MeetingDocument(
            id: 1, uuid: "u", startedAt: Date(timeIntervalSince1970: 0), durationMs: 0, title: nil, status: .ready,
            speakerMode: .diarized, audioState: .deleted, notesMarkdown: notes, notesStatus: .ok,
            notesDroppedCount: 0, speakers: [], segments: segments)
    }

    private func segment(_ id: Int64, _ start: Int, _ text: String, speaker: Int64? = nil)
        -> MeetingDocument.Segment
    {
        .init(id: id, channel: .mic, startMs: start, endMs: start + 500, speakerID: speaker, text: text)
    }

    @Test("a segment is one block whatever it says, and provenance follows the blocks")
    func oneBlockPerSegment() throws {
        let hostile = [
            "```", "~~~ swift", "# heading", "- item", "1. numbered", "| a | b |", "line\nbreak", "  ", "last",
        ]
        let segments = hostile.enumerated().map {
            segment(Int64($0.offset + 1), $0.offset * 1000, $0.element, speaker: 7)
        }
        let layer = try #require(MeetingNoteLayers.transcriptLayer(document(segments: segments)))
        let blocks = MarkdownBlocks.split(layer.markdown)
        #expect(blocks.count == layer.provenance.count)
        #expect(blocks.count == hostile.count - 1)  // the blank segment has no block
        #expect(layer.provenance.map(\.blockIndex) == Array(0..<blocks.count))
        #expect(layer.provenance.allSatisfy { $0.speakerID == "7" })
        #expect(layer.provenance.map(\.segmentRef) == ["1", "2", "3", "4", "5", "6", "7", "9"])
        #expect(layer.provenance.first?.startMs == 0)
    }

    @Test("the notes layer carries the time of each quote")
    func notesQuotes() throws {
        let notes = NotesComposer.markdown(
            verdict: NotesGuard.ReduceVerdict(
                decisions: [NotesPoint(id: "p1", kind: .decision, timeMs: 83_000, quote: "q", text: "Ship it")],
                tasks: [],
                questions: [NotesPoint(id: "p2", kind: .question, timeMs: 3_725_000, quote: "q", text: "Who pays")],
                summary: nil, summaryReplaced: false, rejectedIDs: 0),
            participants: [], labels: .english)
        let layer = try #require(MeetingNoteLayers.notesLayer(document(segments: [], notes: notes)))
        let times = layer.provenance.map(\.quoteTimesMs)
        #expect(times.contains([83_000]))
        #expect(times.contains([3_725_000]))
        #expect(layer.author == .agent)
        #expect(layer.provenance.allSatisfy { $0.speakerID == nil && $0.segmentRef == nil })
    }

    @Test("an empty transcript or notes is no layer")
    func empty() {
        #expect(MeetingNoteLayers.layers(document(segments: [segment(1, 0, "  ")], notes: " \n")).isEmpty)
    }

    @Test("the version changes with the text and the start times, not with speaker ids")
    func version() throws {
        let a = try #require(MeetingNoteLayers.transcriptLayer(document(segments: [segment(1, 0, "hi", speaker: 1)])))
        let sameWithOtherSpeaker = try #require(
            MeetingNoteLayers.transcriptLayer(document(segments: [segment(1, 0, "hi", speaker: 99)])))
        let otherText = try #require(MeetingNoteLayers.transcriptLayer(document(segments: [segment(1, 0, "hey")])))
        let otherStart = try #require(MeetingNoteLayers.transcriptLayer(document(segments: [segment(1, 5, "hi")])))
        #expect(a.version == sameWithOtherSpeaker.version)
        #expect(a.version != otherText.version)
        #expect(a.version != otherStart.version)
    }

    @Test(
        "a speaker rename and a second applySpeakerPlan keep the transcript version; speakers carry id, name and isSelf"
    )
    func versionSurvivesSpeakerChanges() async throws {
        let rig = try NoteSourceRig()
        let key = try rig.key("notes")
        let id = try #require(rig.rig.ids["notes"])
        let before = try #require(try await rig.source.content(for: key))
        let versionBefore = try #require(before.layers.first { $0.id == "transcript" }).version
        let speaker = try #require(before.speakers.first)
        try await rig.source.renameSpeaker(key, speakerID: speaker.id, to: "Anna Nowak")
        let renamed = try #require(try await rig.source.content(for: key))
        #expect(renamed.layers.first { $0.id == "transcript" }?.version == versionBefore)
        #expect(renamed.speakers.map(\.name) == ["Anna Nowak"])

        let segments = try rig.store.loadDocument(id: id)?.segments ?? []
        let plan = SpeakerPlan(
            mode: .diarized,
            speakers: [
                .init(label: "Me", isSelf: true, channel: .mic), .init(label: "Jan", isSelf: false, channel: .system),
            ],
            assignments: Dictionary(uniqueKeysWithValues: segments.map { ($0.id, 1) }))
        try rig.store.applySpeakerPlan(plan, meetingID: id, diarizationModelID: nil)
        try rig.store.applySpeakerPlan(plan, meetingID: id, diarizationModelID: nil)
        let replanned = try #require(try await rig.source.content(for: key))
        #expect(replanned.layers.first { $0.id == "transcript" }?.version == versionBefore)
        #expect(replanned.speakers.map(\.name) == ["Me", "Jan"])
        #expect(replanned.speakers.map(\.isSelf) == [true, false])
        #expect(Set(replanned.speakers.map(\.id)).count == 2)
        // The block still points at its segment while the speaker row was replaced.
        let block = try #require(replanned.layers.first { $0.id == "transcript" }?.provenance.first)
        #expect(block.segmentRef == String(segments[0].id))
    }
}

@MainActor
@Suite("MeetingNoteSource: editing, actions and deleting")
struct MeetingNoteEditingTests {
    @Test("rename title sets it, a blank title clears it, and the notes stay current")
    func renameTitle() async throws {
        let rig = try NoteSourceRig()
        let key = try rig.key("notes")
        try await rig.source.renameTitle(key, to: "  Nowy tytuł \u{200B}")
        #expect(try await rig.source.content(for: key)?.summary.title == "Nowy tytuł")
        #expect(try await rig.source.content(for: key)?.summary.state == .ready)
        try await rig.source.renameTitle(key, to: "   ")
        #expect(try await rig.source.content(for: key)?.summary.title == nil)
    }

    @Test("rename speaker makes the notes stale and refuses a speaker of another meeting")
    func renameSpeaker() async throws {
        let rig = try NoteSourceRig()
        let key = try rig.key("notes")
        let speaker = try #require(try await rig.source.content(for: key)?.speakers.first)
        try await rig.source.renameSpeaker(key, speakerID: speaker.id, to: "Ola")
        #expect(try await rig.source.content(for: key)?.summary.state == .stale)
        await #expect(throws: MeetingEdits.Failure.notFound) {
            try await rig.source.renameSpeaker(rig.key("stale"), speakerID: speaker.id, to: "X")
        }
        await #expect(throws: MeetingNoteSourceError.notFound) {
            try await rig.source.renameSpeaker(key, speakerID: "nope", to: "X")
        }
    }

    @Test("mark self sets the flag and the notes stale; a meeting being recorded refuses")
    func markSelf() async throws {
        let rig = try NoteSourceRig()
        let key = try rig.key("notes")
        let speaker = try #require(try await rig.source.content(for: key)?.speakers.first)
        try await rig.source.markSelf(key, speakerID: speaker.id)
        let content = try #require(try await rig.source.content(for: key))
        #expect(content.speakers.first?.isSelf == true)
        #expect(content.summary.state == .stale)
        // A meeting in recording refuses.
        let live = try rig.store.insertMeeting(
            uuid: "live-1", startedAt: Date(), speechModelID: "m", status: .recording)
        let liveSpeaker = try rig.store.insertSpeaker(meetingID: live, label: "Bob", isSelf: false, channel: .mic)
        await #expect(throws: MeetingEdits.Failure.refused) {
            try await rig.source.markSelf(NoteKey(pluginID: "meetings", id: "live-1"), speakerID: String(liveSpeaker))
        }
    }

    @Test("actions follow the meeting: finish, regenerate and the notes model")
    func actions() async throws {
        let rig = try NoteSourceRig()
        func ids(_ name: String) throws -> [String] { try rig.source.actions(for: rig.key(name)).map(\.id) }
        #expect(try ids("notes") == ["meetings.regenerate"])
        #expect(try ids("failed").isEmpty)
        #expect(try ids("incomplete") == ["meetings.finish"])
        try rig.store.write { db in
            try db.execute(sql: "UPDATE meeting SET audio_state = 'deleted' WHERE status = 'incomplete'")
        }
        #expect(try ids("incomplete").isEmpty)  // the audio is gone: nothing to finish from
        try rig.store.write { db in
            try db.execute(sql: "UPDATE meeting SET audio_state = 'spool' WHERE status = 'incomplete'")
        }
        let id = try #require(rig.rig.ids["plain"])
        rig.board.update {
            $0.enabled = true
            $0.modelMissing = true
            $0.awaitingModel = [id]
        }
        #expect(try ids("plain") == ["meetings.regenerate", "meetings.notesModel"])
        rig.board.update { $0.phases[id] = .queued }
        #expect(try ids("plain") == ["meetings.notesModel"])
        let regenerate = try #require(try rig.source.actions(for: rig.key("notes")).first)
        try await regenerate.perform()
        #expect(rig.regenerated.get() == [try #require(rig.rig.ids["notes"])])
        // Finish without a resumer: the library cannot, so the action reports it.
        let finish = try #require(try rig.source.actions(for: rig.key("incomplete")).first)
        await #expect(throws: MeetingNoteSourceError.unavailable) { try await finish.perform() }
    }

    @Test("delete removes the meeting and its spool and tells the change streams; a live one is refused")
    func delete() async throws {
        let rig = try NoteSourceRig()
        var changes = rig.source.makeChanges().makeAsyncIterator()
        let key = try rig.key("plain")
        try await rig.source.delete(key)
        #expect(await changes.next() != nil)
        #expect(try await rig.source.content(for: key) == nil)
        #expect(try await rig.source.exists([key]).isEmpty)
        try await rig.source.delete(key)  // already gone: no error

        let live = try rig.store.insertMeeting(
            uuid: "live-2", startedAt: Date(), speechModelID: "m", status: .recording)
        await #expect(throws: MeetingNoteSourceError.active) {
            try await rig.source.delete(NoteKey(pluginID: "meetings", id: "live-2"))
        }
        let processing = try rig.store.insertMeeting(
            uuid: "proc-1", startedAt: Date(), speechModelID: "m", status: .processing)
        await #expect(throws: MeetingNoteSourceError.active) {
            try await rig.source.delete(NoteKey(pluginID: "meetings", id: "proc-1"))
        }
        rig.rig.library.registerLive(meetingID: live)
        _ = processing
        #expect(try rig.store.meetingID(uuid: "live-2") == live)
    }

    @Test("a stream ends when the hub finishes, and a new one starts after that")
    func hub() async {
        let hub = NoteChangeHub()
        var first = hub.makeStream().makeAsyncIterator()
        hub.notify()
        hub.notify()
        #expect(await first.next() != nil)
        hub.finishAll()
        #expect(await first.next() == nil)
        var second = hub.makeStream().makeAsyncIterator()
        hub.notify()
        #expect(await second.next() != nil)
    }
}

@MainActor
@Suite("MeetingNoteSource: privacy and keys")
struct MeetingNotePrivacyTests {
    @Test("the source files never log or print")
    func noLogging() throws {
        for name in [
            "MeetingNoteSource.swift", "MeetingNoteLayers.swift", "MeetingNoteMapping.swift", "MeetingEdits.swift",
        ] {
            let text = try String(contentsOf: TestPaths.meetingsSource(named: name), encoding: .utf8)
            for forbidden in ["Logger", "logger", "print(", "NSLog", "os_log", "debugPrint", "dump("] {
                #expect(!text.contains(forbidden), "\(name) uses \(forbidden)")
            }
        }
    }

    @Test("keys stay unique after the library is erased and a meeting is recorded")
    func keysAfterErase() async throws {
        let rig = try NoteSourceRig()
        let oldKeys = Set(try await rig.source.list(matching: nil, after: nil, limit: 10).items.map(\.id))
        #expect(oldKeys.count == 5)
        try rig.rig.library.erase()
        rig.rig.library.open()
        let store = try #require(rig.rig.library.store)
        let id = try store.insertMeeting(
            uuid: UUID().uuidString.lowercased(), startedAt: Date(), speechModelID: "m")
        // The row id starts over, the key does not.
        #expect(id == 1)
        let newKeys = Set(try await rig.source.list(matching: nil, after: nil, limit: 10).items.map(\.id))
        #expect(newKeys.count == 1)
        #expect(newKeys.isDisjoint(with: oldKeys))
        #expect(try await rig.source.exists(Array(oldKeys)).isEmpty)
    }

    @Test("keys are meetings:<uuid>")
    func keyFormat() async throws {
        let rig = try NoteSourceRig()
        let page = try await rig.source.list(matching: nil, after: nil, limit: 1)
        let key = try #require(page.items.first?.id)
        #expect(key.rawValue.hasPrefix("meetings:"))
        #expect(UUID(uuidString: key.id) != nil)
    }
}

@MainActor
@Suite("MeetingsLibraryActions: openNote")
struct MeetingOpenNoteTests {
    private func actions(
        _ rig: LibraryRig, windows: FakeWindows, openNote: (@MainActor (NoteKey) -> Bool)? = nil
    ) -> MeetingsLibraryActions {
        if let openNote {
            return MeetingsLibraryActions(
                library: rig.library, pasteboard: rig.pasteboard, labels: .english, timeZone: ExportFixtures.utc,
                openNote: openNote, makeWindows: { _ in windows })
        }
        // The default handler, as in the shell until step 3.2.
        return MeetingsLibraryActions(
            library: rig.library, pasteboard: rig.pasteboard, labels: .english, timeZone: ExportFixtures.utc,
            makeWindows: { _ in windows })
    }

    @Test("with the default handler (false) ⌘O still opens the meeting window")
    func defaultHandlerOpensTheWindow() throws {
        let rig = try LibraryRig()
        let windows = FakeWindows()
        let id = try #require(rig.ids["notes"])
        actions(rig, windows: windows).open(id)
        #expect(windows.shown == [id])
    }

    @Test("a handler that returns false still opens the window, and sees the meeting's key")
    func decliningHandler() throws {
        let rig = try LibraryRig()
        let windows = FakeWindows()
        let id = try #require(rig.ids["notes"])
        let seen = Shared<[NoteKey]>([])
        actions(rig, windows: windows) { key in
            seen.update { $0.append(key) }
            return false
        }.open(id)
        #expect(windows.shown == [id])
        #expect(seen.get() == [NoteKey(pluginID: "meetings", id: try #require(try rig.store.meetingUUID(id: id)))])
    }

    @Test("a handler that returns true gets the key and no window opens")
    func acceptingHandler() throws {
        let rig = try LibraryRig()
        let windows = FakeWindows()
        let id = try #require(rig.ids["notes"])
        let seen = Shared<[NoteKey]>([])
        actions(rig, windows: windows) { key in
            seen.update { $0.append(key) }
            return true
        }.open(id)
        #expect(windows.shown.isEmpty)
        #expect(seen.get().count == 1)
        #expect(seen.get().first?.pluginID == "meetings")
    }

    @Test("the library's ⌘O action goes through open")
    func theActionUsesIt() async throws {
        let rig = try LibraryRig()
        let windows = FakeWindows()
        let handled = Shared<Int>(0)
        let actions = actions(rig, windows: windows) { _ in
            handled.update { $0 += 1 }
            return true
        }
        let source = MeetingsLibrarySource(store: { rig.library.store }, actions: actions)
        let row = try #require(
            try await source.search(NormalizedQuery(raw: "", normalized: ""), filter: nil, limit: 5).first)
        let open = try #require(source.actions(for: row).first { $0.id == "meetings.library.open" })
        #expect(open.shortcut == KeyShortcut(key: "o", modifiers: .command))
        try await open.perform(ActionContext(previousApp: nil, panel: rig.panel))
        #expect(handled.get() == 1)
        #expect(windows.shown.isEmpty)
    }
}

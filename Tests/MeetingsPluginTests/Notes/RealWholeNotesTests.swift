import Foundation
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// The development harness of the quality gate G (spec `2026-11-10-external-ai-providers`, step 1.7e): the
/// whole-transcript track with a REAL provider model, started by hand, outside the app. Off by default; CI never
/// sets the variable, and nothing in the app calls the provider.
///
///     LINTEL_WHOLE_NOTES_CLAUDE=1 [LINTEL_WHOLE_NOTES_MODEL=sonnet] [LINTEL_WHOLE_NOTES_RUNS=1] \
///       swift test --filter RealWholeNotesTests
///
/// The input is the synthetic corpus. With `LINTEL_WHOLE_NOTES_REAL=<export dir>[,<export dir>]` (an export of
/// `segments.jsonl`, `speakers.json`, `meta.json`) and `LINTEL_WHOLE_NOTES_OUT=<dir under /Volumes/LintelMeetingEval/work>`
/// real meetings are sent too; their notes and the raw answers are written ONLY to that directory, and only
/// numbers are printed. The child process gets the isolation flags of ADR 0011 and an allowlisted environment.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_WHOLE_NOTES_CLAUDE"] != nil), .serialized)
struct RealWholeNotesTests {
    private static let environment = ProcessInfo.processInfo.environment

    @Test func theSyntheticCorpusOnTheProviderModel() async throws {
        guard Self.environment["LINTEL_WHOLE_NOTES_ONLY"] != "real" else { return }
        let runs = Int(Self.environment["LINTEL_WHOLE_NOTES_RUNS"] ?? "1") ?? 1
        var totals = WholeNotesRubric()
        var all: [String] = []
        for run in 1...runs {
            for corpus in try WholeNotesCase.all() {
                let generator = ClaudeCLIGenerator(model: Self.environment["LINTEL_WHOLE_NOTES_MODEL"] ?? "sonnet")
                let started = ContinuousClock.now
                let result = try await WholeNotesPipeline(generator: generator).run(
                    utterances: corpus.utterances, durationMs: corpus.durationMs)
                let seconds = Self.seconds(ContinuousClock.now - started)
                let final = generator.lastText.map { NotesDraftParser.parse($0).draft } ?? NotesDraft()
                let checked = NotesFactGuard(utterances: corpus.utterances, durationMs: corpus.durationMs).check(final)
                let rubric = WholeNotesRubric.score(draft: checked.draft, gold: corpus.gold)
                if let out = Self.environment["LINTEL_WHOLE_NOTES_OUT"] {
                    let directory = URL(filePath: out).appending(path: "synthetic")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try (result.markdown ?? "").write(
                        to: directory.appending(path: "\(corpus.name)-run\(run)-notes.md"), atomically: true,
                        encoding: .utf8)
                }
                totals.decisionsExpected += rubric.decisionsExpected
                totals.decisionsFound += rubric.decisionsFound
                totals.tasksExpected += rubric.tasksExpected
                totals.tasksFound += rubric.tasksFound
                totals.tasksWithCorrectPerson += rubric.tasksWithCorrectPerson
                totals.openExpected += rubric.openExpected
                totals.openFound += rubric.openFound
                let kept = Set(
                    checked.draft.decisions.map(\.text) + checked.draft.tasks.map(\.text) + checked.draft.open
                        + checked.draft.topics.flatMap(\.points))
                let removed =
                    (final.decisions.map(\.text) + final.tasks.map(\.text) + final.open + final.topics.flatMap(\.points))
                    .filter { !kept.contains($0) }
                    + (checked.draft.summary == final.summary ? [] : ["SUMMARY: " + (final.summary ?? "")])
                all.append(contentsOf: removed.map { "REMOVED \(corpus.name)#\(run): \($0)" })
                all.append(contentsOf: rubric.unmatched.map { "\(corpus.name)#\(run): \($0)" })
                print(
                    "WHOLE-G synthetic name=\(corpus.name) run=\(run) status=\(result.status.rawValue) "
                        + "decisions=\(rubric.decisionsFound)/\(rubric.decisionsExpected) tasks=\(rubric.tasksFound)/\(rubric.tasksExpected) "
                        + "persons=\(rubric.tasksWithCorrectPerson)/\(rubric.tasksExpected) open=\(rubric.openFound)/\(rubric.openExpected) "
                        + "unmatched=\(rubric.unmatched.count) dropped=\(checked.report.dropped) personReset=\(checked.report.personReset) "
                        + "dueRemoved=\(checked.report.dueRemoved) words=\(rubric.words) calls=\(generator.callCount) "
                        + "inTok=\(generator.inputTokens) outTok=\(generator.outputTokens) seconds=\(String(format: "%.1f", seconds))"
                )
            }
        }
        let found = totals.decisionsFound + totals.tasksFound
        let expected = totals.decisionsExpected + totals.tasksExpected
        print(
            "WHOLE-G synthetic TOTAL decisionsAndTasks=\(found)/\(expected) persons=\(totals.tasksWithCorrectPerson)/\(totals.tasksExpected) "
                + "unmatched=\(all.count)")
        for line in all { print("WHOLE-G unmatched-synthetic \(line)") }
    }

    @Test func realMeetingsOnTheProviderModel() async throws {
        guard let list = Self.environment["LINTEL_WHOLE_NOTES_REAL"],
            Self.environment["LINTEL_WHOLE_NOTES_ONLY"] != "synthetic"
        else { return }
        let out = URL(filePath: try #require(Self.environment["LINTEL_WHOLE_NOTES_OUT"]))
        try #require(
            out.path.hasPrefix("/Volumes/LintelMeetingEval/work/"), "real content goes only to the encrypted image")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for path in list.split(separator: ",").map(String.init) {
            let directory = URL(filePath: path)
            let id = directory.lastPathComponent
            let document = try Self.loadExport(directory)
            let utterances = NotesUtterance.make(from: document)
            let generator = ClaudeCLIGenerator(model: Self.environment["LINTEL_WHOLE_NOTES_MODEL"] ?? "sonnet")
            let started = ContinuousClock.now
            let result = try await WholeNotesPipeline(generator: generator).run(
                utterances: utterances, durationMs: document.durationMs)
            let seconds = Self.seconds(ContinuousClock.now - started)
            let final = generator.lastText.map { NotesDraftParser.parse($0).draft } ?? NotesDraft()
            let checked = NotesFactGuard(utterances: utterances, durationMs: document.durationMs).check(final)
            let name = "m\(id)-\(ProcessInfo.processInfo.environment["LINTEL_WHOLE_NOTES_TAG"] ?? "run")"
            try (result.markdown ?? "").write(
                to: out.appending(path: name + "-notes.md"), atomically: true, encoding: .utf8)
            try generator.allTexts.joined(separator: "\n=====\n").write(
                to: out.appending(path: name + "-raw.txt"), atomically: true, encoding: .utf8)
            let kept = Set(
                checked.draft.decisions.map(\.text) + checked.draft.tasks.map(\.text) + checked.draft.open
                    + checked.draft.topics.flatMap(\.points))
            let removed =
                (final.decisions.map(\.text) + final.tasks.map(\.text) + final.open + final.topics.flatMap(\.points))
                .filter { !kept.contains($0) }
            try removed.joined(separator: "\n").write(
                to: out.appending(path: name + "-removed.txt"), atomically: true, encoding: .utf8)
            let words = utterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let notesWords = (result.markdown ?? "").split(whereSeparator: \.isWhitespace).count
            let report = checked.report
            print(
                "WHOLE-G real meeting=\(id) utterances=\(utterances.count) words=\(words) estTokens=\(NotesText.estimateTokens(WholeNotesPrompt.transcriptLines(utterances))) "
                    + "status=\(result.status.rawValue) parts=\(result.chunkCount) calls=\(generator.callCount) "
                    + "notesWords=\(notesWords) decisions=\(checked.draft.decisions.count) tasks=\(checked.draft.tasks.count) "
                    + "topics=\(checked.draft.topics.count) open=\(checked.draft.open.count) "
                    + "tasksWithPerson=\(checked.draft.tasks.filter { $0.person != nil }.count) "
                    + "dropped=\(report.dropped) byRule=\(report.droppedByRule.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: ",")) "
                    + "personReset=\(report.personReset) dueRemoved=\(report.dueRemoved) timesOmitted=\(report.timesOmitted) "
                    + "shapeStripped=\(report.shapeStripped) cut=\(report.cutToLimit) "
                    + "inTok=\(generator.inputTokens) outTok=\(generator.outputTokens) seconds=\(String(format: "%.1f", seconds))"
            )
        }
    }

    /// The guard again over answers stored by an earlier run (`-raw.txt`): no provider call, so a guard change
    /// can be measured without sending anything.
    @Test func theGuardOverStoredAnswers() throws {
        guard let list = Self.environment["LINTEL_WHOLE_NOTES_REAL"],
            let tag = Self.environment["LINTEL_WHOLE_NOTES_TAG"],
            Self.environment["LINTEL_WHOLE_NOTES_OFFLINE"] != nil
        else { return }
        let out = URL(filePath: try #require(Self.environment["LINTEL_WHOLE_NOTES_OUT"]))
        try #require(out.path.hasPrefix("/Volumes/LintelMeetingEval/work/"))
        for path in list.split(separator: ",").map(String.init) {
            let directory = URL(filePath: path)
            let document = try Self.loadExport(directory)
            let utterances = NotesUtterance.make(from: document)
            let raw = try String(
                contentsOf: out.appending(path: "m\(directory.lastPathComponent)-\(tag)-raw.txt"), encoding: .utf8)
            let last = raw.components(separatedBy: "\n=====\n").last ?? ""
            let checked = NotesFactGuard(utterances: utterances, durationMs: document.durationMs).check(
                NotesDraftParser.parse(last).draft)
            let report = checked.report
            print(
                "WHOLE-G offline meeting=\(directory.lastPathComponent) decisions=\(checked.draft.decisions.count) "
                    + "tasks=\(checked.draft.tasks.count) topics=\(checked.draft.topics.count) open=\(checked.draft.open.count) "
                    + "dropped=\(report.dropped) byRule=\(report.droppedByRule.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: ",")) "
                    + "personReset=\(report.personReset) dueRemoved=\(report.dueRemoved)")
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// `segments.jsonl`, `speakers.json` and `meta.json` of an export folder as a document.
    static func loadExport(_ directory: URL) throws -> MeetingDocument {
        struct Segment: Decodable {
            var id: Int64
            var channel: String
            var startMs: Int
            var endMs: Int
            var speakerId: Int64?
            var text: String
        }
        struct Speaker: Decodable {
            var id: Int64
            var isSelf: Int
            var label: String
            var sourceChannel: String
        }
        struct Meta: Decodable {
            var durationMs: Int
            var speakerMode: String
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let meta = try decoder.decode(Meta.self, from: Data(contentsOf: directory.appending(path: "meta.json")))
        let speakers = try decoder.decode(
            [Speaker].self, from: Data(contentsOf: directory.appending(path: "speakers.json")))
        let segments = try String(contentsOf: directory.appending(path: "segments.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try decoder.decode(Segment.self, from: Data($0.utf8)) }
        return MeetingDocument(
            id: 1, uuid: "export", startedAt: Date(timeIntervalSince1970: 0), durationMs: meta.durationMs, title: nil,
            status: .ready, speakerMode: SpeakerMode(rawValue: meta.speakerMode) ?? .diarized, audioState: .deleted,
            notesMarkdown: nil, notesStatus: .none, notesDroppedCount: 0,
            speakers: speakers.map {
                .init(
                    id: $0.id, label: $0.label, isSelf: $0.isSelf != 0,
                    channel: AudioChannel(rawValue: $0.sourceChannel) ?? .mic)
            },
            segments: segments.map {
                .init(
                    id: $0.id, channel: AudioChannel(rawValue: $0.channel) ?? .mic, startMs: $0.startMs,
                    endMs: $0.endMs,
                    speakerID: $0.speakerId, text: $0.text)
            })
    }
}

/// A `NotesGenerating` over the Claude Code CLI with the isolation flags of ADR 0011. Test-only: the app has no
/// such generator. The prompt goes through stdin; the child gets an allowlisted environment and an empty folder.
final class ClaudeCLIGenerator: NotesGenerating, @unchecked Sendable {
    struct Failure: Error { var detail: String }

    let profile = NotesGeneratorProfile(
        strategy: .wholeTranscript, inputBudgetTokens: 100_000, promptFormat: WholeNotesPrompt.version + "+cli1")
    private let model: String
    private let state = Mutex((texts: [String](), input: 0, output: 0))

    init(model: String) { self.model = model }

    var allTexts: [String] { state.withLock { $0.texts } }
    var lastText: String? { state.withLock { $0.texts.last } }
    var callCount: Int { state.withLock { $0.texts.count } }
    var inputTokens: Int { state.withLock { $0.input } }
    var outputTokens: Int { state.withLock { $0.output } }

    func open() async throws {}
    func release() async {}

    func generateResult(
        messages: [ChatMessage], maxTokens: Int, onPhase: (@Sendable (GenerationPhase) -> Void)?
    ) async throws -> GenerationResult {
        let serialized = ProviderPromptSerializer.serialize(messages)
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let binary = environment["LINTEL_CLAUDE_PATH"] ?? home + "/.local/bin/claude"
        let work = FileManager.default.temporaryDirectory.appending(path: "whole-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": work.path]
        for name in ["HOME", "USER", "LANG", "CLAUDE_CONFIG_DIR"] { env[name] = environment[name] }

        let process = Process()
        process.executableURL = URL(filePath: binary)
        process.arguments = [
            "-p", "--model", model, "--output-format", "json", "--tools", "", "--no-session-persistence",
            "--disable-slash-commands", "--strict-mcp-config", "--setting-sources", "", "--system-prompt",
            serialized.system,
        ]
        process.environment = env
        process.currentDirectoryURL = work
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try process.run()
                    DispatchQueue.global().async {
                        try? input.fileHandleForWriting.write(contentsOf: Data(serialized.input.utf8))
                        try? input.fileHandleForWriting.close()
                    }
                    DispatchQueue.global().async { _ = try? error.fileHandleForReading.readToEnd() }
                    let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                    process.waitUntilExit()
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        struct Reply: Decodable {
            struct Usage: Decodable {
                var inputTokens: Int?
                var cacheCreationInputTokens: Int?
                var cacheReadInputTokens: Int?
                var outputTokens: Int?
            }
            var result: String?
            var isError: Bool?
            var usage: Usage?
        }
        let reply = try {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Reply.self, from: data)
        }()
        let usage = reply.usage
        state.withLock {
            $0.input +=
                (usage?.inputTokens ?? 0) + (usage?.cacheCreationInputTokens ?? 0)
                + (usage?.cacheReadInputTokens ?? 0)
            $0.output += usage?.outputTokens ?? 0
        }
        let text = reply.result ?? ""
        if reply.isError == true {
            if text.hasPrefix("API Error: Claude's response exceeded") {
                return GenerationResult(text: "", stoppedByTokenLimit: true)
            }
            throw Failure(detail: "provider error")
        }
        state.withLock { $0.texts.append(text) }
        return GenerationResult(text: text, stoppedByTokenLimit: false)
    }
}

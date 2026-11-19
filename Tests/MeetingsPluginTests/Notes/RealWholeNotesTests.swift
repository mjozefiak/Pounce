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
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["LINTEL_WHOLE_NOTES_CLAUDE"] != nil
            || ProcessInfo.processInfo.environment["LINTEL_WHOLE_NOTES_LLAMA_URL"] != nil), .serialized)
struct RealWholeNotesTests {
    private static let environment = ProcessInfo.processInfo.environment

    /// The Claude Code CLI, or, with `LINTEL_WHOLE_NOTES_LLAMA_URL=http://127.0.0.1:<port>`, a `llama-server` that
    /// the tester started by hand on a local model (model comparison; the context is the server's `-c`).
    static func makeGenerator() -> any HarnessGenerator {
        if let url = environment["LINTEL_WHOLE_NOTES_LLAMA_URL"], let base = URL(string: url) {
            let budget = Int(environment["LINTEL_WHOLE_NOTES_BUDGET"] ?? "") ?? 24_000
            return LlamaServerGenerator(base: base, inputBudgetTokens: budget)
        }
        return ClaudeCLIGenerator(model: environment["LINTEL_WHOLE_NOTES_MODEL"] ?? "sonnet")
    }

    @Test func theSyntheticCorpusOnTheProviderModel() async throws {
        guard Self.environment["LINTEL_WHOLE_NOTES_ONLY"] != "real" else { return }
        let runs = Int(Self.environment["LINTEL_WHOLE_NOTES_RUNS"] ?? "1") ?? 1
        var totals = WholeNotesRubric()
        var all: [String] = []
        for run in 1...runs {
            for corpus in try WholeNotesCase.all() {
                let generator = Self.makeGenerator()
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
                        to: directory.appending(
                            path:
                                "\(corpus.name)-\(Self.environment["LINTEL_WHOLE_NOTES_TAG"] ?? "run")-run\(run)-notes.md"
                        ), atomically: true,
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
            let generator = Self.makeGenerator()
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

/// What the harness reads back from a generator besides the answer.
protocol HarnessGenerator: NotesGenerating {
    var allTexts: [String] { get }
    var lastText: String? { get }
    var callCount: Int { get }
    var inputTokens: Int { get }
    var outputTokens: Int { get }
}

extension ClaudeCLIGenerator: HarnessGenerator {}

/// A `NotesGenerating` over a `llama-server` on the loopback (test-only; the tester starts the server on a GGUF
/// file by hand). Greedy sampling, no thinking, one request per call; the prompt goes in the request body only.
final class LlamaServerGenerator: HarnessGenerator, @unchecked Sendable {
    struct Failure: Error { var detail: String }

    let profile: NotesGeneratorProfile
    private let base: URL
    private let state = Mutex((texts: [String](), input: 0, output: 0))

    init(base: URL, inputBudgetTokens: Int) {
        self.base = base
        profile = NotesGeneratorProfile(
            strategy: .wholeTranscript, inputBudgetTokens: inputBudgetTokens,
            promptFormat: WholeNotesPrompt.version + "+llama")
    }

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
        guard base.host == "127.0.0.1" else { throw Failure(detail: "loopback only") }
        let serialized = ProviderPromptSerializer.serialize(messages)
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": serialized.system], ["role": "user", "content": serialized.input],
            ],
            "temperature": 0, "max_tokens": maxTokens, "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var request = URLRequest(url: base.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]], let first = choices.first,
            let message = first["message"] as? [String: Any], let text = message["content"] as? String
        else { throw Failure(detail: "bad reply") }
        let usage = json["usage"] as? [String: Any]
        state.withLock {
            $0.input += usage?["prompt_tokens"] as? Int ?? 0
            $0.output += usage?["completion_tokens"] as? Int ?? 0
        }
        let cut = (first["finish_reason"] as? String) == "length"
        if !cut { state.withLock { $0.texts.append(text) } }
        return GenerationResult(text: cut ? "" : text, stoppedByTokenLimit: cut)
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

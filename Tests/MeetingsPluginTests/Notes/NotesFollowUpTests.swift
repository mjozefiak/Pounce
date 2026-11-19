import Foundation
import Testing

@testable import MeetingsPlugin

/// Follow-ups to the summary P0 (issue #142): the fallback pick over the whole meeting, a retry that changes the
/// prompt, a task listed once, no small-talk tasks, no questions without a subject, no problem without a verdict.
@Suite struct NotesFollowUpTests {
    private static func point(
        _ id: String, _ kind: NotesPointKind, at seconds: Int, text: String = "Text", person: String? = nil,
        due: String? = nil
    ) -> NotesPoint {
        NotesPoint(
            id: id, kind: kind, timeMs: seconds * 1000, quote: "quote \(id)", text: text, person: person, due: due,
            speaker: nil)
    }

    private static func verified(_ lines: [(String, String)], _ points: [NotesPoint]) -> NotesGuard.PointVerdict {
        let utterances = lines.enumerated().map {
            NotesUtterance(startMs: $0.offset * 10_000, speaker: "Anna", text: $0.element.1)
        }
        return NotesGuard(utterances: utterances).verifyPoints(points)
    }

    // MARK: The fallback pick

    @Test func theFallbackSpreadsTopicsOverTheWholeMeetingInTimeOrder() {
        let points = (0..<30).map { Self.point("p\($0 + 1)", .summary, at: $0 * 60) }
        let output = NotesPipeline.codeOrder(points)
        #expect(output.keyPoints.count == NotesGuard.maxKeyPoints)
        let times = output.keyPoints.compactMap { id in points.first { $0.id == id }?.timeMs }
        #expect(times == times.sorted())
        #expect(times.first == 0)
        // The first, middle and last thirds are all there, not only the first ten.
        let thirds = Set(times.map { $0 / 600_000 })
        #expect(thirds == [0, 1, 2])
        #expect(times.last ?? 0 >= 25 * 60_000)
    }

    @Test func theSpreadFollowsTimeNotCountWhenPointsAreUneven() {
        let times = [0, 1, 2, 3, 4, 5, 600, 1200]
        let points = times.enumerated().map { Self.point("p\($0.offset + 1)", .summary, at: $0.element) }
        let picked = NotesPipeline.spread(points, count: 3).map(\.timeMs)
        #expect(picked == [0, 600_000, 1_200_000])
    }

    @Test func theSpreadKeepsEveryPointWhenThereAreFewAndIsDeterministic() {
        let points = (0..<4).map { Self.point("p\($0)", .summary, at: $0) }
        #expect(NotesPipeline.spread(points, count: 10) == points)
        #expect(NotesPipeline.spread(points, count: 0).isEmpty)
        let many = (0..<50).map { Self.point("p\($0)", .summary, at: $0 * 7) }
        #expect(NotesPipeline.spread(many, count: 10) == NotesPipeline.spread(many, count: 10))
    }

    @Test func theFallbackSpreadsTheQuestionsAndKeepsAllDecisionsAndTasks() {
        var points = (0..<12).map { Self.point("q\($0)", .question, at: $0 * 100) }
        points.append(Self.point("d1", .decision, at: 5))
        points.append(Self.point("t1", .task, at: 900))
        let output = NotesPipeline.codeOrder(points)
        #expect(output.questions.count == NotesGuard.maxQuestions)
        #expect(output.questions.contains("q11"))
        #expect(output.decisions == ["d1"] && output.tasks == ["t1"])
        #expect(output.summary == nil)
    }

    @Test func aReduceThatFailsLeavesTopicsFromTheMiddleOfTheMeeting() async throws {
        let subjects = (0..<30).map { "alpha\($0) beta\($0 * 2 + 1) gamma\($0 * 3 + 2) delta\($0 * 5 + 7)" }
        let utterances = subjects.enumerated().map {
            NotesUtterance(startMs: $0.offset * 60_000, speaker: "Anna", text: "Subject \($0.element) is covered.")
        }
        let rig = NotesRig { _, messages, _ in
            if NotesFake.isMap(messages) {
                let lines = NotesFake.transcriptLines(messages).map { line -> String in
                    let quote = line.text.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return "SUM | \(line.time) | \"\(quote)\" | \(quote)."
                }
                return .done(lines.joined(separator: "\n"))
            }
            return .done("I cannot help with that.")
        }
        let result = try await rig.pipeline().run(utterances: utterances)
        #expect(result.status == .partial)
        let numbers = (result.markdown ?? "").matches(of: /Subject alpha(\d+)\s/).compactMap { Int($0.output.1) }
        #expect(numbers.count == NotesGuard.maxKeyPoints)
        #expect(numbers.contains { $0 >= 10 && $0 < 20 }, "the middle of the meeting is missing")
        #expect(numbers.contains { $0 >= 20 })
    }

    // MARK: The retry

    @Test func aReduceCutOffByTheTokenLimitIsAskedAgainWithAChangedPrompt() async throws {
        let seen = Mutex2()
        let rig = NotesRig { call, messages, _ in
            if NotesFake.isMap(messages) { return .done(NotesFake.mapAnswer(messages)) }
            guard NotesFake.isReduce(messages) else { return .done("SUMMARY: x") }
            seen.add(NotesFake.lastUser(messages))
            if NotesFake.lastUser(messages).contains(NotesPrompt.formatReminder) {
                return .done(NotesFake.reduceAnswer(messages, summary: "Spotkanie dotyczyło zatwierdzania punktów."))
            }
            return .cutOff("SUMMARY: loop\nDECISIONS: p1, p1, p1, p1")
        }
        let result = try await rig.pipeline().run(utterances: decisionLines(count: 3))
        #expect(result.status == .ok)
        #expect(!result.reduceFailed)
        let prompts = seen.all
        #expect(prompts.count == 2)
        #expect(prompts[0] != prompts[1])
    }

    // MARK: Tasks

    @Test func aTaskListedTwiceStandsOnceAndKeepsThePersonAndDateOfEither() {
        let guardian = NotesGuard(utterances: [])
        let first = Self.point("p1", .task, at: 10, text: "Send the offer to the client.", person: nil, due: "Friday")
        let second = Self.point("p2", .task, at: 300, text: "Send the offer to the client.", person: "Marek")
        let other = Self.point("p3", .task, at: 400, text: "Write the rollout checklist.", person: "Anna")
        let verdict = guardian.verifyReduce(
            NotesReduceOutput(tasks: ["p1", "p2", "p3"]), points: [first, second, other])
        #expect(verdict.tasks.map(\.id) == ["p1", "p3"])
        #expect(verdict.tasks[0].person == "Marek")
        #expect(verdict.tasks[0].due == "Friday")
    }

    @Test func aBackfilledTaskThatRepeatsAListedOneIsNotAddedAndTwoPeopleStayApart() {
        let guardian = NotesGuard(utterances: [])
        let a = Self.point("p1", .task, at: 10, text: "Prepare the report.", person: "Anna")
        let b = Self.point("p2", .task, at: 20, text: "Prepare the report.", person: "Marek")
        let c = Self.point("p3", .task, at: 30, text: "Prepare the report.", person: "Anna", due: "Monday")
        let verdict = guardian.verifyReduce(NotesReduceOutput(tasks: ["p1"]), points: [a, b, c])
        #expect(verdict.tasks.map(\.id) == ["p1", "p2"])
        #expect(verdict.tasks[0].due == "Monday")
    }

    @Test func aTaskThatIsSmallTalkIsDroppedAndRealWorkStays() {
        let lines = [
            ("a", "Ewa, bring coffee for everyone on Monday."), ("b", "See you next week and enjoy the weekend."),
            ("c", "Marek, please send the offer to the client."),
        ]
        let verdict = Self.verified(
            lines,
            [
                NotesPoint(
                    id: "p1", kind: .task, timeMs: 0, quote: "Ewa, bring coffee for everyone on Monday",
                    text: "Bring coffee for everyone.", person: "Ewa", due: "Monday", speaker: nil),
                NotesPoint(
                    id: "p2", kind: .task, timeMs: 10_000, quote: "See you next week and enjoy the weekend",
                    text: "See everyone next week.", person: nil, due: nil, speaker: nil),
                NotesPoint(
                    id: "p3", kind: .task, timeMs: 20_000, quote: "Marek, please send the offer to the client",
                    text: "Send the offer to the client.", person: "Marek", due: nil, speaker: nil),
            ])
        #expect(verdict.verified.map(\.id) == ["p3"])
        #expect(verdict.reasons[.nonWorkTask] == 2)
    }

    @Test(arguments: [
        ("Marek, bring coffee.", true), ("Przynieś kawę na poniedziałek.", true), ("See you on Monday.", true),
        ("Do zobaczenia w piątek.", true), ("Share your screen please.", true),
        ("Send the offer to the client.", false), ("Przygotuj raport do piątku.", false),
        ("Book the training room.", false),
    ])
    func theNonWorkRuleLooksForOneThingEach(text: String, nonWork: Bool) {
        #expect(NotesRelevance.isNonWorkTask(text: text, quote: text) == nonWork)
    }

    // MARK: Questions without context

    @Test(arguments: [
        ("When will it be ready?", true), ("Is that okay?", true), ("Kiedy to będzie gotowe?", true),
        ("Czy to jest ok?", true), ("Who will handle the contract with the supplier?", false),
        ("Kto zajmie się umową z dostawcą?", false), ("Who owns billing?", false),
        ("When will the offer be ready?", false), ("Can we ship on Friday?", false),
    ])
    func aQuestionNeedsTwoWordsThatSayWhatItIsAbout(text: String, withoutContext: Bool) {
        #expect(NotesRelevance.isContextFreeQuestion(text) == withoutContext)
    }

    @Test func aContextFreeQuestionIsDroppedAndOneWithASubjectStays() {
        let lines = [("a", "When will it be ready?"), ("b", "Who will handle the contract with the supplier?")]
        let verdict = Self.verified(
            lines,
            [
                NotesPoint(
                    id: "p1", kind: .question, timeMs: 0, quote: "When will it be ready",
                    text: "When will it be ready?"),
                NotesPoint(
                    id: "p2", kind: .question, timeMs: 10_000, quote: "Who will handle the contract with the supplier",
                    text: "Who will handle the contract with the supplier?"),
            ])
        #expect(verdict.verified.map(\.id) == ["p2"])
        #expect(verdict.reasons[.questionWithoutContext] == 1)
    }

    // MARK: Reports

    @Test(arguments: [
        ("The export job fails on large files.", true), ("Eksport nie działa dla dużych plików.", true),
        ("The export job fails because the temp folder is full.", false),
        ("The login bug only happens when the session has expired.", false),
        ("Błąd eksportu wynika z pełnego dysku, więc trzeba go wyczyścić.", false),
        ("The budget is eight thousand.", false),
    ])
    func aProblemNeedsACauseAConditionAFixOrANextStep(text: String, withoutVerdict: Bool) {
        #expect(NotesRelevance.isReportWithoutVerdict(text) == withoutVerdict)
    }

    @Test func aFindingThatOnlyReportsAProblemIsDropped() {
        let lines = [
            ("a", "The export job fails on large files."),
            ("b", "The export job fails because the temp folder is full."),
        ]
        let verdict = Self.verified(
            lines,
            [
                NotesPoint(
                    id: "p1", kind: .summary, timeMs: 0, quote: "The export job fails on large files",
                    text: "The export job fails on large files."),
                NotesPoint(
                    id: "p2", kind: .summary, timeMs: 10_000,
                    quote: "The export job fails because the temp folder is full",
                    text: "The export job fails because the temp folder is full."),
            ])
        #expect(verdict.verified.map(\.id) == ["p2"])
        #expect(verdict.reasons[.reportWithoutVerdict] == 1)
    }

    // MARK: The prompt

    @Test func theMapPromptAsksForWorkTasksSelfContainedQuestionsAndVerdicts() {
        let english = NotesPrompt.mapSystem(language: .english)
        #expect(english.contains("Only work for the project"))
        #expect(english.contains("a reader can understand alone"))
        #expect(english.contains("only with its verdict"))
        #expect(NotesPrompt.mapSystem(language: .polish).contains("to samo zadanie wpisujesz raz"))
        #expect(NotesPrompt.reduceSystem.contains("whole meeting"))
    }
}

/// The prompts a model closure saw.
final class Mutex2: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

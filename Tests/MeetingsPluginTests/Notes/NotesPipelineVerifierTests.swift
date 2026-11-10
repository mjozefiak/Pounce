import Foundation
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// A verifier the test scripts: a verdict by claim text, and every request it was asked.
final class FakeNotesVerifier: NotesVerifying, @unchecked Sendable {
    typealias Script = @Sendable (_ call: Int, _ request: NotesVerificationRequest) async -> NotesVerification

    private let requests = Mutex<[NotesVerificationRequest]>([])
    private let script: Script

    init(_ script: @escaping Script) { self.script = script }

    convenience init(_ verdicts: [String: NotesVerification], otherwise: NotesVerification) {
        self.init { _, request in verdicts[request.text] ?? otherwise }
    }

    var asked: [NotesVerificationRequest] { requests.withLock { $0 } }

    func verify(_ request: NotesVerificationRequest) async -> NotesVerdict {
        await verification(request).verdict
    }

    func verification(_ request: NotesVerificationRequest) async -> NotesVerification {
        let call = requests.withLock { list -> Int in
            list.append(request)
            return list.count
        }
        return await script(call, request)
    }

    var factory: NotesVerifierFactory { { _ in self } }
}

/// The semantic verifier in `NotesPipeline`: what it is asked, what its answers change, and that it fails closed.
@Suite struct NotesPipelineVerifierTests {
    static let driftedText = "Rozmowa dotyczyła finansów firmy i planowania wydatków."
    static let driftedQuote = "Zaczynamy spotkanie o budżecie na przyszły kwartał."
    static let decisionText = "Zatwierdzono budżet marketingowy w wysokości czterdziestu tysięcy złotych."
    static let taskText = "Wysłać ofertę do klienta."
    static let negatedText = "Umowa nie zostanie przygotowana."

    /// p1 a summary point that drifts (repaired, restorable), p2 a kept decision, p3 a kept task, p4 a decision
    /// whose negation is turned around (repaired, never sent).
    static let mapAnswer = """
        SUM | 0:05 | "Zaczynamy spotkanie o budżecie na przyszły kwartał" | \(driftedText)
        DEC | 0:21 | "Zatwierdzamy budżet marketingowy w wysokości czterdziestu tysięcy złotych" | \(decisionText)
        TASK | 0:34 | "Marek wyśle ofertę do klienta w piątek" | \(taskText) | Marek | piątek
        DEC | 0:47 | "Ja przygotuję umowę" | \(negatedText)
        """

    /// REDUCE's paragraph: not the text of p1, so p1 (in either wording) stays a key point the tests can read.
    static let reduceSummary = "Spotkanie dotyczyło budżetu marketingowego i oferty do klienta."

    static func handler(verifierAnswer: String? = nil) -> ScriptedLLM.Handler {
        { _, messages, _ in
            if NotesFake.isMap(messages) { return .done(mapAnswer) }
            if NotesFake.isReduce(messages) { return .done(NotesFake.reduceAnswer(messages, summary: reduceSummary)) }
            if messages.first?.content == NotesVerifierPrompt.system {
                return .done(verifierAnswer ?? NotesFake.answer(messages))
            }
            return .done(NotesFake.answer(messages))
        }
    }

    static func answered(_ verdict: NotesVerdict) -> NotesVerification {
        NotesVerification(verdict: verdict, source: .answered)
    }

    static let failed = NotesVerification(verdict: .unsupported, source: .failed)

    /// The built-in verifier built explicitly: these tests do not depend on `notesVerifierEnabled`.
    static let builtInVerifier: NotesVerifierFactory = { @Sendable runtime in LLMNotesVerifier(runtime: runtime) }

    private func run(
        verifier: NotesVerifierFactory?, handler: @escaping ScriptedLLM.Handler = handler(),
        configure: (inout NotesPipeline.Configuration) -> Void = { _ in }, log: NotesTraceLog? = nil
    ) async throws -> (NotesResult, NotesRig) {
        let rig = NotesRig(handler)
        var configuration = NotesPipeline.Configuration()
        configure(&configuration)
        let sink: NotesTraceSink? = log.map { log -> NotesTraceSink in { log.add($0) } }
        let pipeline = NotesPipeline(model: rig.model, configuration: configuration, trace: sink, verifier: verifier)
        return (try await pipeline.run(utterances: GuardFixtures.transcript()), rig)
    }

    private static func text(of id: String, in result: NotesResult) -> String? {
        (result.keyPoints + result.points).first { $0.id == id }?.text
    }

    private static func verifierTrace(_ log: NotesTraceLog) -> NotesTraceVerification? {
        for event in log.all { if case .verified(let verification) = event { return verification } }
        return nil
    }

    // MARK: What is asked

    @Test func theNegationRepairIsNeverAskedAndEveryOtherPointIs() async throws {
        let fake = FakeNotesVerifier([:], otherwise: Self.failed)
        let (result, _) = try await run(verifier: fake.factory)
        #expect(Set(fake.asked.map(\.text)) == [Self.driftedText, Self.decisionText, Self.taskText])
        #expect(!fake.asked.contains { $0.text.contains("nie zostanie") })
        // The task's request is its text and the quote as the guard sees them.
        let task = try #require(fake.asked.first { $0.kind == .task })
        #expect(task.quote == "Marek wyśle ofertę do klienta w piątek.")
        #expect(task.context.count == 5)
        // Failed answers change nothing.
        let (control, _) = try await run(verifier: nil)
        #expect(result == control)
    }

    // MARK: Repaired points

    @Test func supportedRestoresTheModelTextOfARepairedPoint() async throws {
        let fake = FakeNotesVerifier(
            [Self.driftedText: Self.answered(.supported)], otherwise: Self.answered(.supported))
        let log = NotesTraceLog()
        let (result, _) = try await run(verifier: fake.factory, log: log)
        let (control, _) = try await run(verifier: nil)
        #expect(Self.text(of: "p1", in: control) == Self.driftedQuote)
        #expect(Self.text(of: "p1", in: result) == Self.driftedText)
        #expect(result.repairedCount == control.repairedCount - 1)
        // The negation repair stays a repair.
        #expect(Self.text(of: "p4", in: result) == "Ja przygotuję umowę.")
        let counters = try #require(Self.verifierTrace(log)?.verifier)
        #expect(counters.eligible == 3)
        #expect(counters.asked == 3)
        #expect(counters.supported == 3)
        #expect(counters.restoredModelText == 1)
        #expect(counters.rejectedKept == 0)
        #expect(counters.promptVersion == NotesVerifierPrompt.version)
        #expect(!counters.budgetExceeded)
    }

    @Test func weakerUnsupportedOrFailedKeepTheExcerpt() async throws {
        for verdict in [Self.answered(.weaker), Self.answered(.unsupported), Self.failed] {
            let fake = FakeNotesVerifier([Self.driftedText: verdict], otherwise: Self.answered(.supported))
            let (result, _) = try await run(verifier: fake.factory)
            #expect(Self.text(of: "p1", in: result) == Self.driftedQuote, "\(verdict)")
        }
    }

    // MARK: Kept points

    @Test func aKeptPointTheVerifierRejectsShowsItsQuote() async throws {
        let fake = FakeNotesVerifier([Self.decisionText: Self.answered(.weaker)], otherwise: Self.failed)
        let log = NotesTraceLog()
        let (result, _) = try await run(verifier: fake.factory, log: log)
        #expect(
            Self.text(of: "p2", in: result)
                == "Zatwierdzamy budżet marketingowy w wysokości czterdziestu tysięcy złotych.")
        #expect(Self.text(of: "p3", in: result) == Self.taskText)
        let verification = try #require(Self.verifierTrace(log))
        #expect(verification.repairReasons[.verifierRejected] == 1)
        #expect(verification.verifier?.rejectedKept == 1)
        #expect(verification.verifier?.weaker == 1)
        #expect(verification.verifier?.failed == 2)
    }

    @Test func aFailedVerdictOnAKeptPointLeavesItUnchanged() async throws {
        for failure in [NotesVerification.Source.failed, .malformed, .cutOff, .cancelled] {
            let fake = FakeNotesVerifier([:], otherwise: NotesVerification(verdict: .unsupported, source: failure))
            let (result, _) = try await run(verifier: fake.factory)
            #expect(Self.text(of: "p2", in: result) == Self.decisionText, "\(failure)")
            #expect(Self.text(of: "p3", in: result) == Self.taskText, "\(failure)")
        }
    }

    // MARK: The built-in verifier on the notes' own model

    @Test func theDefaultVerifierAsksTheNotesModelThroughTheLease() async throws {
        let (restored, rig) = try await run(
            verifier: Self.builtInVerifier, handler: Self.handler(verifierAnswer: "VERDICT: SUPPORTED"))
        #expect(rig.llm.calls.filter { $0.messages.first?.content == NotesVerifierPrompt.system }.count == 3)
        #expect(Self.text(of: "p1", in: restored) == Self.driftedText)
        #expect(await rig.waitUntilReleased())

        let (rejected, _) = try await run(
            verifier: Self.builtInVerifier, handler: Self.handler(verifierAnswer: "VERDICT: UNSUPPORTED"))
        #expect(Self.text(of: "p2", in: rejected)?.hasPrefix("Zatwierdzamy") == true)
        #expect(Self.text(of: "p1", in: rejected) == Self.driftedQuote)
    }

    @Test func aModelThatDoesNotAnswerInTheFormatChangesNothing() async throws {
        // The fake model answers a verifier prompt with a summary line: malformed, so every verdict failed.
        let log = NotesTraceLog()
        let (result, _) = try await run(verifier: Self.builtInVerifier, log: log)
        let (control, _) = try await run(verifier: nil)
        #expect(result == control)
        let counters = try #require(Self.verifierTrace(log)?.verifier)
        #expect(counters.failed == 3)
        #expect(counters.rejectedKept == 0)
        #expect(counters.restoredModelText == 0)
    }

    /// Fails loudly on purpose when `notesVerifierEnabled` is flipped to `true`: whoever switches the verifier on
    /// must update this test (and decide what the default pipeline should be asked) in the same change.
    @Test func theSwitchIsOffAndTheDefaultPipelineAsksNoVerifierQuestion() async throws {
        #expect(
            NotesPipeline.notesVerifierEnabled == false,
            "notesVerifierEnabled was flipped: update this test and the default-pipeline expectations")
        #expect(NotesPipeline.defaultVerifier == nil)
        let rig = NotesRig(Self.handler(verifierAnswer: "VERDICT: SUPPORTED"))
        let pipeline = NotesPipeline(model: rig.model)
        _ = try await pipeline.run(utterances: GuardFixtures.transcript())
        let questions = rig.llm.calls.filter { $0.messages.first?.content == NotesVerifierPrompt.system }
        #expect(questions.isEmpty, "the default pipeline asked the verifier \(questions.count) question(s)")
    }

    // MARK: Cancellation and time

    @Test func cancellingTheRunWhileTheVerifierWorksThrows() async throws {
        let entered = Flag()
        let fake = FakeNotesVerifier { _, _ in
            entered.set()
            try? await Task.sleep(for: .seconds(3600))
            return NotesVerification(verdict: .unsupported, source: .cancelled)
        }
        let rig = NotesRig(Self.handler())
        let pipeline = NotesPipeline(model: rig.model, verifier: fake.factory)
        let task = Task { try await pipeline.run(utterances: GuardFixtures.transcript()) }
        for _ in 0..<500 where !entered.isSet { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entered.isSet)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fake.asked.count == 1)
        #expect(await rig.waitUntilReleased())
    }

    @Test func pointsLeftWhenTheTimeRunsOutKeepTheGuardsResult() async throws {
        let fake = FakeNotesVerifier { call, _ in
            if call == 1 { return Self.answered(.supported) }
            try? await Task.sleep(for: .seconds(3600))
            return Self.answered(.unsupported)
        }
        let log = NotesTraceLog()
        let (result, _) = try await run(
            verifier: fake.factory, configure: { $0.verifierBudget = .milliseconds(200) }, log: log)
        #expect(result.status == .ok)
        // The first point (p1, repaired) got its answer in time; the kept ones got none and stay as they were.
        #expect(Self.text(of: "p1", in: result) == Self.driftedText)
        #expect(Self.text(of: "p2", in: result) == Self.decisionText)
        #expect(Self.text(of: "p3", in: result) == Self.taskText)
        let counters = try #require(Self.verifierTrace(log)?.verifier)
        #expect(counters.budgetExceeded)
        #expect(counters.asked == 1)
        #expect(counters.notAsked == 2)
        #expect(counters.rejectedKept == 0)
    }

    // MARK: Trace

    @Test func theVerifierCountersHoldNoText() async throws {
        let fake = FakeNotesVerifier(
            [Self.driftedText: Self.answered(.supported), Self.decisionText: Self.answered(.unsupported)],
            otherwise: Self.answered(.weaker))
        let log = NotesTraceLog()
        _ = try await run(verifier: fake.factory, log: log)
        let verification = try #require(Self.verifierTrace(log))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(verification), as: UTF8.self)
        let described = json + String(describing: verification) + String(reflecting: verification)
        var words = Set<String>()
        for utterance in GuardFixtures.transcript() {
            words.formUnion(Self.words(utterance.text))
            words.formUnion(Self.words(utterance.speaker))
        }
        words.formUnion(Self.words(Self.mapAnswer))
        words.subtract(["sum", "dec", "task"])
        let leaked = words.intersection(Self.words(described))
        #expect(leaked.isEmpty, "\(leaked.sorted())")
        #expect(described.contains("restoredModelText"))
        #expect(try JSONDecoder().decode(NotesTraceVerification.self, from: Data(json.utf8)) == verification)

        // A trace written before the verifier has no counters and still reads.
        var object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object.removeValue(forKey: "verifier")
        let older = try JSONDecoder().decode(
            NotesTraceVerification.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.verifier == nil)
        #expect(older.repaired == verification.repaired)
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
    }
}

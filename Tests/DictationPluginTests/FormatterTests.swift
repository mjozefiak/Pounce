import Foundation
import Synchronization
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

/// A formatter driven by a closure, for the session and controller tests.
struct StubFormatter: TextFormatter {
    let body: @Sendable (String, String?) async throws -> FormatResult

    init(_ body: @escaping @Sendable (String, String?) async throws -> FormatResult) {
        self.body = body
    }

    func format(chunk: String, previousContext: String?) async throws -> FormatResult {
        try await body(chunk, previousContext)
    }
}

/// Answers `LocalLLMFormatter` from a script and records the requests.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Answer {
        case content(String)
        case raw(String, status: Int)
        case failure(URLError.Code)
    }

    private let answers: Mutex<[Answer]>
    private let seen = Mutex<[URLRequest]>([])

    init(_ answers: Answer...) { self.answers = Mutex(answers) }

    var requests: [URLRequest] { seen.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.withLock { $0.append(request) }
        let answer = answers.withLock { $0.count > 1 ? $0.removeFirst() : ($0.first ?? .failure(.badServerResponse)) }
        let url = request.url ?? URL(fileURLWithPath: "/")
        switch answer {
        case .content(let text):
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .raw(let body, let status):
            return (
                Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        case .failure(let code):
            throw URLError(code)
        }
    }
}

@Suite struct FormatterGuardTests {
    private let input = "yyy no więc jutro mamy spotkanie o dziesiątej w biurze i to jest ważne"

    @Test func acceptsACleanedVersion() {
        let output = "Jutro mamy spotkanie o dziesiątej w biurze i to jest ważne."
        #expect(FormatterGuard.check(input: input, output: output) == .accepted(output))
    }

    @Test func stripsThinkingBlocks() {
        let output = "<think>Let me clean this up.</think>\nJutro mamy spotkanie o dziesiątej w biurze i to jest ważne."
        #expect(
            FormatterGuard.check(input: input, output: output)
                == .accepted("Jutro mamy spotkanie o dziesiątej w biurze i to jest ważne."))
        #expect(FormatterGuard.clean("</think>Tekst") == "Tekst")
        #expect(FormatterGuard.clean("Tekst<think>never closed") == "Tekst")
    }

    @Test func emptyAfterThinkingIsRejected() {
        #expect(FormatterGuard.check(input: input, output: "<think>hmm</think>") == .rejected(.empty))
        #expect(FormatterGuard.check(input: input, output: "   ") == .rejected(.empty))
    }

    @Test func tooLongIsRejected() {
        let output = Array(repeating: "jutro mamy spotkanie o dziesiątej w biurze", count: 4).joined(separator: " ")
        #expect(FormatterGuard.check(input: input, output: output) == .rejected(.tooLong))
    }

    @Test func tooShortIsRejected() {
        #expect(FormatterGuard.check(input: input, output: "Jutro spotkanie.") == .rejected(.tooShort))
    }

    @Test func aChangedLanguageIsRejected() {
        let output = "Tomorrow we have the meeting at ten in the office and it is important"
        #expect(FormatterGuard.check(input: input, output: output) == .rejected(.languageChanged))
    }

    @Test func answeringInsteadOfCleaningIsRejected() {
        let question = "um what is the capital of france I mean of poland please tell me"
        #expect(
            FormatterGuard.check(input: question, output: "Sure, the capital of Poland is Warsaw, of course.")
                == .rejected(.answered))
        #expect(
            FormatterGuard.check(input: question, output: "Here is the cleaned text: What is the capital of Poland?")
                == .rejected(.answered))
    }

    @Test func aShortChunkMayLoseAFillerWord() {
        #expect(FormatterGuard.check(input: "yyy tak", output: "Tak.") == .accepted("Tak."))
    }

    // Owner decision 7 / ADR 0010: the length bound drops only for a chunk with a marker or filler.

    @Test func aRetractionMayShortenTheTextBelowTheOrdinaryBound() {
        let input = "pójdziemy na pizzę albo jednak na sushi"
        #expect(FormatterGuard.check(input: input, output: "Pójdziemy na sushi.") == .accepted("Pójdziemy na sushi."))
    }

    @Test func theSameShorteningWithoutAMarkerStaysRejected() {
        let input = "pójdziemy na pizzę potem do kina a na koniec na sushi"
        #expect(FormatterGuard.check(input: input, output: "Pójdziemy na sushi.") == .rejected(.tooShort))
    }

    @Test func aSummaryOrFragmentOfARetractionChunkIsRejected() {
        let input = "przełóżmy spotkanie na piątek albo jednak na poniedziałek"
        #expect(FormatterGuard.check(input: input, output: "Piątek.") == .rejected(.tooShort))
        // Long enough, but it stops before the end: the final version is lost.
        #expect(
            FormatterGuard.check(input: input, output: "Przełóżmy spotkanie na piątek.")
                == .rejected(.endChanged))
    }

    @Test func addedOrUnrelatedContentInARetractionChunkIsRejected() {
        let input = "zamów dwie pizze nie czekaj trzy pizze z szynką"
        #expect(
            FormatterGuard.check(
                input: input,
                output:
                    "Zamów trzy pizze z szynką i ananasem dla wszystkich gości oraz przygotuj jeszcze deser i napoje.")
                == .rejected(.tooLong))
        #expect(
            FormatterGuard.check(input: input, output: "Pogoda jutro będzie ładna w całym kraju.")
                == .rejected(.endChanged))
        #expect(FormatterGuard.check(input: input, output: "") == .rejected(.empty))
        #expect(FormatterGuard.check(input: input, output: "<think>x</think>") == .rejected(.empty))
    }

    @Test func aRetractionChunkStillCannotBeAnsweredOrTranslated() {
        let input = "what is the capital of france no wait of poland please tell me"
        #expect(FormatterGuard.check(input: input, output: "Sure, it is Warsaw.") == .rejected(.answered))
        let polish = "pójdziemy na pizzę albo jednak na sushi"
        #expect(
            FormatterGuard.check(input: polish, output: "We will go and eat some sushi now")
                == .rejected(.languageChanged))
    }

    @Test func writingTheNumberAsDigitsIsNotAddedContent() {
        let input = "spotkanie jest o dziesiątej nie to znaczy o jedenastej w sali numer 5"
        #expect(
            FormatterGuard.check(input: input, output: "Spotkanie jest o 11 w sali numer 5.")
                == .accepted("Spotkanie jest o 11 w sali numer 5."))
    }

    // The relaxed length bound is anchored to a marker (owner decision 7 / ADR 0010, review of PR #134).

    private func rejected(_ input: String, _ output: String) -> Bool {
        if case .rejected = FormatterGuard.check(input: input, output: output) { return true }
        return false
    }

    @Test func wordsThatAreNotMarkersNeverRelaxTheBound() {
        // "albo", "nie", "or" and "no" alone are ordinary words: a 50% cut stays too short.
        let polish = "weźmiemy ser albo szynkę potem pójdziemy do domu albo do kina nie w piątek"
        #expect(FormatterGuard.check(input: polish, output: "Weźmiemy ser albo szynkę potem.") == .rejected(.tooShort))
        let english = "we can take the bus or the tram then walk home or call a cab no problem at all"
        #expect(
            FormatterGuard.check(input: english, output: "We can take the bus or the tram.") == .rejected(.tooShort))
    }

    @Test(arguments: [
        // A marker word used as content, and the model cuts a middle or a tail that no marker anchors.
        (
            "ten rower jest jednak droższy niż myślałem ale dobrze jeździ po lesie i po mieście",
            "Ten rower jeździ po lesie i po mieście."
        ),
        (
            "ta kurtka jest właściwie za duża na mnie ale ciepła i lekka więc zabiorę ją w góry",
            "Ta kurtka jest ciepła w góry."
        ),
        (
            "zamknij okno i czekaj na kuriera w przedpokoju bo dzwonek jest zepsuty od zeszłego tygodnia",
            "Zamknij okno od zeszłego tygodnia."
        ),
        (
            "it's actually cheaper to rent the van for a week than to buy one and pay for parking every month",
            "It's cheaper to rent the van for a week every month."
        ),
        (
            "please wait for the electrician in the hallway because the bell is broken since last week",
            "Please wait for the electrician since last week."
        ),
        (
            "I'm sorry to say the garden gate was left open all night and then the dog ran off down the road",
            "I'm sorry to say the gate ran off down the road."
        ),
    ])
    func aMarkerWordUsedAsContentDoesNotLicenseACutMiddleOrTail(input: String, output: String) {
        #expect(rejected(input, output))
    }

    @Test func aLongChunkCannotLoseItsContentBeforeAMarkerNearTheEnd() {
        let input =
            "nasza ekipa przyjedzie z samego rana rozłoży narzędzia sprawdzi instalację elektryczną w całym budynku "
            + "potem pomaluje korytarz i klatkę schodową nie czekaj pomaluje tylko klatkę"
        #expect(rejected(input, "Nasza ekipa pomaluje tylko klatkę."))
        // The honest version of the same retraction: only the retracted part and the marker go.
        let honest =
            "Nasza ekipa przyjedzie z samego rana, rozłoży narzędzia, sprawdzi instalację elektryczną w całym budynku "
            + "potem pomaluje tylko klatkę."
        #expect(FormatterGuard.check(input: input, output: honest) == .accepted(honest))
    }

    @Test func aMarkerAtTheStartRetractsNothing() {
        let polish = "przepraszam że się spóźniłem ale korek na obwodnicy był naprawdę duży dziś rano"
        #expect(rejected(polish, "Przepraszam, korek był duży dziś rano."))
        let english = "actually the train was late again so we missed the first talk of the morning"
        #expect(rejected(english, "Actually the train missed the morning."))
    }

    @Test(arguments: [
        // Held-out retractions: not in the corpus, markers from the closed list, only the retraction goes.
        ("przynieś z piwnicy drabinę nie czekaj dwie drabiny i wiadro", "Przynieś z piwnicy dwie drabiny i wiadro."),
        (
            "zaplanuj wizytę u lekarza na wtorek albo jednak na czwartek o ósmej trzydzieści",
            "Zaplanuj wizytę u lekarza na czwartek o ósmej trzydzieści."
        ),
        (
            "rower kosztuje dwieście złotych a właściwie dwieście pięćdziesiąt złotych z dostawą",
            "Rower kosztuje 250 złotych z dostawą."
        ),
        (
            "umówiliśmy się na basenie to znaczy na hali sportowej o osiemnastej",
            "Umówiliśmy się na hali sportowej o osiemnastej."
        ),
        (
            "put the ladder in the garage no wait in the shed behind the house",
            "Put the ladder in the shed behind the house."
        ),
        ("the library closes at five I mean at six on weekdays", "The library closes at six on weekdays."),
        ("we need twelve chairs sorry fourteen chairs for the hall", "We need 14 chairs for the hall."),
        ("call the plumber on tuesday scratch that on wednesday morning", "Call the plumber on Wednesday morning."),
    ])
    func aHeldOutRetractionIsAccepted(input: String, output: String) {
        #expect(FormatterGuard.check(input: input, output: output) == .accepted(output))
    }

    /// Known limitation: the guard cannot tell a negated imperative from a retraction marker. "nie czekaj" here
    /// is an instruction to someone else, yet the output that drops everything before it is derivable from
    /// the input, so it is accepted. Only the prompt (keep both versions when unsure) and the raw text
    /// (`dictation.pasteLastRaw`) protect the user in this case.
    @Test func aNegatedImperativeLooksLikeARetractionToTheGuard() {
        let input = "napisz Piotrkowi nie czekaj na mnie z kolacją"
        #expect(
            FormatterGuard.check(input: input, output: "Na mnie z kolacją.") == .accepted("Na mnie z kolacją."))
    }

    @Test func attacksOnARetractionChunkAreRejected() {
        let input = "zanieś paczkę do sąsiada nie czekaj do dozorcy przed szóstą"
        #expect(FormatterGuard.check(input: input, output: "") == .rejected(.empty))
        #expect(FormatterGuard.check(input: input, output: "  \n ") == .rejected(.empty))
        // An answer to a dictated question.
        let question = "what is the capital of france no wait of poland please tell me"
        #expect(rejected(question, "The capital of Poland is Warsaw."))
        // A translation, an unrelated text of the same length, a preface.
        #expect(
            FormatterGuard.check(input: input, output: "Take the parcel to the caretaker before six.")
                == .rejected(.languageChanged))
        #expect(rejected(input, "Pogoda w górach będzie jutro słoneczna i bardzo ciepła."))
        #expect(
            FormatterGuard.check(
                input: input, output: "Here is the cleaned text: Zanieś paczkę do dozorcy przed szóstą.")
                == .rejected(.answered))
        // Longer than 1.15 times the input.
        let longer = input + " i jeszcze zadzwoń do administracji w sprawie windy oraz klatki"
        #expect(FormatterGuard.check(input: input, output: longer) == .rejected(.tooLong))
        // A truncated start (the marker is near the end) and a truncated end.
        let long =
            "przygotuj dokumenty dla klienta z Poznania i sprawdź wszystkie załączniki przed wysyłką nie czekaj "
            + "wyślij je jutro rano"
        #expect(rejected(long, "Sprawdź wszystkie załączniki przed wysyłką, wyślij je jutro rano."))
        #expect(FormatterGuard.check(input: input, output: "Zanieś paczkę do dozorcy.") == .rejected(.endChanged))
    }

    @Test func languageDetection() {
        #expect(Language.dominant(in: "to jest bardzo ważne i nie ma czasu na to") == .polish)
        #expect(Language.dominant(in: "this is the thing that we should have done") == .english)
        #expect(Language.dominant(in: "ok") == .unknown)
    }
}

@Suite struct LocalLLMFormatterTests {
    private let base = URL(string: "http://127.0.0.1:11434")!
    private let chunk = "yyy no więc jutro mamy spotkanie o dziesiątej w biurze i to jest ważne"

    private func formatter(_ transport: ScriptedTransport, configured: Bool = true) -> LocalLLMFormatter {
        LocalLLMFormatter(
            transport: transport, target: { [base] in configured ? .init(baseURL: base, model: "qwen") : nil })
    }

    @Test func aGoodAnswerIsUsed() async throws {
        let transport = ScriptedTransport(.content("Jutro mamy spotkanie o dziesiątej w biurze i to jest ważne."))
        let result = try await formatter(transport).format(chunk: chunk, previousContext: nil)
        #expect(
            result == .init(text: "Jutro mamy spotkanie o dziesiątej w biurze i to jest ważne.", outcome: .formatted))
    }

    @Test func thinkingIsRemoved() async throws {
        let transport = ScriptedTransport(
            .content("<think>x</think>Jutro mamy spotkanie o dziesiątej w biurze i to jest ważne."))
        let result = try await formatter(transport).format(chunk: chunk, previousContext: nil)
        #expect(result.outcome == .formatted)
        #expect(!result.text.contains("think"))
    }

    @Test(arguments: [
        ("Sure, here you go", FormatterGuard.Reason.answered),
        ("Jutro.", FormatterGuard.Reason.tooShort),
        ("Tomorrow we have the meeting at ten in the office and it is important", .languageChanged),
        (String(repeating: "jutro mamy spotkanie w biurze ", count: 5), .tooLong),
        ("<think>only thoughts</think>", .empty),
    ])
    func aBadAnswerFallsBackToTheRawChunk(answer: String, reason: FormatterGuard.Reason) async throws {
        let transport = ScriptedTransport(.content(answer))
        let result = try await formatter(transport).format(chunk: chunk, previousContext: nil)
        #expect(result == .init(text: chunk, outcome: .fellBack(.rejected(reason))))
    }

    @Test func aTimeoutFallsBackToRaw() async throws {
        let transport = ScriptedTransport(.failure(.timedOut))
        let result = try await formatter(transport).format(chunk: chunk, previousContext: nil)
        #expect(result == .init(text: chunk, outcome: .fellBack(.unreachable)))
        #expect(transport.requests.count == 1)
    }

    @Test func anHTTPErrorFallsBackToRaw() async throws {
        let transport = ScriptedTransport(.raw("{}", status: 500))
        let result = try await formatter(transport).format(chunk: chunk, previousContext: nil)
        #expect(result == .init(text: chunk, outcome: .fellBack(.unreachable)))
    }

    @Test func aConnectionErrorIsRetriedOnce() async throws {
        let transport = ScriptedTransport(
            .failure(.cannotConnectToHost),
            .content("Jutro mamy spotkanie o dziesiątej w biurze i to jest ważne."))
        let result = try await formatter(transport).format(chunk: chunk, previousContext: nil)
        #expect(result.outcome == .formatted)
        #expect(transport.requests.count == 2)

        let down = ScriptedTransport(.failure(.cannotConnectToHost))
        let failed = try await formatter(down).format(chunk: chunk, previousContext: nil)
        #expect(failed.outcome == .fellBack(.unreachable))
        #expect(down.requests.count == 2)
    }

    @Test func garbageIsABadResponse() async throws {
        let transport = ScriptedTransport(.raw("not json", status: 200))
        let result = try await formatter(transport).format(chunk: chunk, previousContext: nil)
        #expect(result == .init(text: chunk, outcome: .fellBack(.badResponse)))
    }

    @Test func withoutAServerTheChunkStaysRaw() async throws {
        let transport = ScriptedTransport(.content("x"))
        let result = try await formatter(transport, configured: false).format(chunk: chunk, previousContext: nil)
        #expect(result == .init(text: chunk, outcome: .fellBack(.notConfigured)))
        #expect(transport.requests.isEmpty)
    }

    @Test func theRequestIsDeterministicAndNotStreamed() async throws {
        let transport = ScriptedTransport(.content("Jutro mamy spotkanie o dziesiątej w biurze i to jest ważne."))
        _ = try await formatter(transport).format(chunk: chunk, previousContext: "Poprzedni akapit.")
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "qwen")
        #expect(body["temperature"] as? Int == 0)
        #expect(body["stream"] as? Bool == false)
        let words = FormatterGuard.words(in: chunk)
        #expect(body["max_tokens"] as? Int == words * 4 + 64)
        let kwargs = body["chat_template_kwargs"] as? [String: Bool]
        #expect(kwargs == ["enable_thinking": false])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.first?["role"] == "system")
        let last = try #require(messages.last?["content"])
        #expect(last.contains("<transcript>\(chunk)</transcript>"))
        #expect(last.contains("<context>Poprzedni akapit.</context>"))
        #expect(request.timeoutInterval == LocalLLMFormatter.timeout(forWords: words))
    }

    @Test func theTimeoutGrowsWithTheChunk() {
        #expect(LocalLLMFormatter.timeout(forWords: 60) == 17)
        #expect(LocalLLMFormatter.timeout(forWords: 0) == 5)
    }

    @Test func cancellationIsNotAFallback() async {
        let transport = ScriptedTransport(.failure(.cancelled))
        await #expect(throws: CancellationError.self) {
            _ = try await formatter(transport).format(chunk: chunk, previousContext: nil)
        }
    }
}

@Suite struct CleanupPromptTests {
    @Test func promptMatchesTheSnapshot() throws {
        let rendered =
            CleanupPrompt.messages(transcript: "TRANSCRIPT", context: "CONTEXT")
            .map { "[\($0.role)]\n\($0.content)" }.joined(separator: "\n\n") + "\n"
        if ProcessInfo.processInfo.environment["LINTEL_RECORD_SNAPSHOT"] != nil {
            let source = URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "Fixtures/cleanup/prompt-v2.txt")
            try rendered.write(to: source, atomically: true, encoding: .utf8)
        }
        let url = try #require(Bundle.module.url(forResource: "Fixtures/cleanup/prompt-v2", withExtension: "txt"))
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(
            rendered == expected,
            "The cleanup prompt changed. Bump CleanupPrompt.version, update the snapshot and note it in the release notes."
        )
        #expect(CleanupPrompt.version == 2)
    }

    @Test func transcriptsAreDelimitedAndQuestionsAreExamples() {
        let messages = CleanupPrompt.messages(transcript: "co to jest", context: nil)
        #expect(messages.last?.content == "<transcript>co to jest</transcript>")
        #expect(messages.first?.content.contains("never a request") == true)
        #expect(CleanupPrompt.examples.contains { $0.output.hasSuffix("?") })
    }
}

import Foundation
import LintelCore

/// The structure REDUCE returns: the ids of the points for each section and a paragraph. Nothing in it is
/// trusted yet; `NotesGuard.verifyReduce` checks the ids and the paragraph.
struct NotesReduceOutput: Equatable, Sendable {
    var decisions: [String] = []
    var tasks: [String] = []
    var questions: [String] = []
    /// The findings REDUCE chose for "Topics discussed", the most important first (at most
    /// `NotesGuard.maxKeyPoints` are shown).
    var keyPoints: [String] = []
    var summary: String?
}

/// The defence against a model that invents (spec: Architecture → Notatki, pkt 4). Pure; it runs twice:
/// after MAP on the points (`verifyPoints`) and after REDUCE on the structure (`verifyReduce`).
///
/// What is guaranteed after `verifyPoints`:
/// - A point is kept only when its quote is in the transcript: inside ONE sentence of one utterance, or across
///   two neighbouring utterances of the same speaker when the first has no sentence end (a sentence the
///   recognizer cut in two). Never spliced across sentences or speakers. The comparison is on normalised words
///   and a word may differ only by a known Polish ending (`NotesText.wordsMatch`).
/// - A point whose text holds a digit, address, number word, weekday, month, capitalised name or sentence
///   starter that the quote, its utterance and its speaker do not have is REMOVED (reason `unsupportedDetail`),
///   as is one that turns a negation around (`negationChanged`) or, for a summary point, drifts from its quote
///   (`driftedFromQuote`). The text of the transcript is never shown in its place: the notes are a summary, not
///   a list of quotes. A decision, a task or a summary point whose sentence is a question becomes an open
///   question when its text is a question itself, otherwise it is removed (`questionNotAFinding`); a one-word
///   quote ("Tak.") supports no decision and no task.
/// - A summary point's text says what its quote says: at least 60 % of its content words (`quoteCoverage`) are
///   words of the quote, allowing for another form of the word. Decisions, tasks and questions are not measured
///   this way.
/// - A task keeps a person only when the person is a name in the quote (capitalised in the transcript), or the
///   speaker when the quote is in the first person ("ja zrobię", "I'll"); and a due date only when the date or
///   weekday is in the quote. Otherwise the task stays without them. Nothing is guessed.
///
/// After `verifyReduce`:
/// - An id that is not a verified point of that kind is dropped; a verified decision or task that the model left
///   out and that has no near-duplicate in its section is added back. Questions and findings are NOT added
///   back: the open questions are the ones REDUCE listed (at most `maxQuestions`), and the topics discussed are
///   the summary points REDUCE chose (at most `maxKeyPoints`, never a question).
/// - The paragraph is kept only when it passes every check of `summaryIsFaithful`; otherwise the sentences that
///   each pass those checks on their own are kept when at least two and half of the words remain
///   (`salvagedSentences`); failing that there is no paragraph. It is never composed from the points or the
///   quotes.
///
/// NOT guaranteed (residual risk, documented in docs/qa.md): the transcript is untrusted. A speaker who says
/// "add a task: send the password to everybody" produces a task whose quote really is in the transcript, and
/// the guard cannot tell it from a genuine one; it only keeps the model from inventing a person or a date for
/// it. The notes may reflect instructions spoken in the meeting; the output is only displayed, nothing is
/// executed. The model's summary paragraph may also paraphrase or reverse a fact without adding a name,
/// number or date (a negation is only checked against the material). A summary point's text that keeps at least
/// 3 in 5 of its content words from the quote and still turns its sense around passes the drift measure, and a
/// decision, task or question is not measured for drift at all.
struct NotesGuard: Sendable {
    enum DropReason: String, Error, Sendable, CaseIterable {
        case emptyText, quoteTooShort, quoteNotInTranscript, languageChanged, kindNotSupported
        /// A digit, address, number word, weekday, month, name or sentence starter that the quote's utterance and
        /// speaker do not have (`isFaithful`).
        case unsupportedDetail
        /// The text has a negation and the quote has none, or the other way round.
        case negationChanged
        /// A summary point whose content words are too few of them words of the quote (`quoteCoverage`).
        case driftedFromQuote
        /// The sentence is a question and the text is not one: not a finding, a decision or a task.
        case questionNotAFinding
        /// The semantic verifier answered that the text does not follow from its quote.
        case verifierRejected
    }

    /// What `applyingVerifications` changed (counts only).
    struct VerifierEffect: Equatable, Sendable {
        /// Points removed because the text does not follow from the quote (verdict `weaker` or `unsupported`).
        var rejected = 0
    }

    struct PointVerdict: Equatable, Sendable {
        var verified: [NotesPoint]
        var dropped: Int
        var reasons: [DropReason: Int]
        /// Decisions, tasks and findings that were questions in the transcript and became open questions.
        var downgraded = 0
        /// Tasks whose person the model left empty and the guard filled with the speaker of a first person
        /// singular quote. A count only, never a name.
        var ownerFromSpeaker = 0
    }

    struct ReduceVerdict: Equatable, Sendable {
        var decisions: [NotesPoint]
        var tasks: [NotesPoint]
        var questions: [NotesPoint]
        var summary: String?
        /// The model's paragraph was refused (`summary` is what is salvaged from it, or nil).
        var summaryReplaced: Bool
        /// Ids the model returned that are unknown or in the wrong section.
        var rejectedIDs: Int
        /// Verified points the model left out that were added back.
        var backfilled = 0
        /// The verified summary points REDUCE chose, in its order: at most `maxKeyPoints`, never a near-duplicate
        /// of one listed before it, a question or a point whose whole text is a sentence of the paragraph.
        var keyPoints: [NotesPoint] = []

        var hasItems: Bool { !(decisions.isEmpty && tasks.isEmpty && questions.isEmpty) }
    }

    private let utterances: [NotesUtterance]
    private let words: [String]
    private let capitalised: [Bool]
    private let startsSentence: [Bool]
    private let charStart: [Int]
    private let charEnd: [Int]
    private let wordUtterance: [Int]
    private let wordSentence: [Int]
    private let sentenceRanges: [Range<Int>]
    private let sentenceTerminators: [Character?]
    private let utteranceRanges: [Range<Int>]
    private let speakerNames: [String]
    private let nameCandidates: Vocabulary
    /// The dominant language of the whole transcript.
    let language: NotesLanguage

    init(utterances: [NotesUtterance]) {
        self.utterances = utterances
        var words: [String] = []
        var capitalised: [Bool] = []
        var starts: [Bool] = []
        var charStart: [Int] = []
        var charEnd: [Int] = []
        var owner: [Int] = []
        var sentenceOf: [Int] = []
        var ranges: [Range<Int>] = []
        var terminators: [Character?] = []
        var utteranceRanges = Array(repeating: 0..<0, count: utterances.count)
        var current = -1
        var open = false
        var previousSpeaker: String?
        for (index, utterance) in utterances.enumerated() {
            let tokens = NotesText.tokens(utterance.text)
            guard !tokens.isEmpty else { continue }
            let first = words.count
            for (position, token) in tokens.enumerated() {
                let continues = position == 0 && open && previousSpeaker == utterance.speaker && current >= 0
                if position > 0, let end = token.sentenceEnd { terminators[current] = end }
                if (position == 0 && !continues) || (position > 0 && token.sentenceEnd != nil) {
                    current += 1
                    ranges.append(words.count..<words.count)
                    terminators.append(nil)
                }
                words.append(token.word)
                capitalised.append(token.capitalised)
                starts.append(token.startsSentence)
                charStart.append(token.start)
                charEnd.append(token.end)
                owner.append(index)
                sentenceOf.append(current)
                ranges[current] = ranges[current].lowerBound..<words.count
            }
            utteranceRanges[index] = first..<words.count
            let last = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).last
            let terminated = last.map { ".!?\u{2026}".contains($0) } ?? false
            if terminated { terminators[current] = last }
            open = !terminated
            previousSpeaker = utterance.speaker
        }
        self.words = words
        self.capitalised = capitalised
        startsSentence = starts
        self.charStart = charStart
        self.charEnd = charEnd
        wordUtterance = owner
        wordSentence = sentenceOf
        sentenceRanges = ranges
        sentenceTerminators = terminators
        self.utteranceRanges = utteranceRanges
        speakerNames = Array(Set(utterances.map(\.speaker))).sorted()
        language = NotesLanguage.dominant(in: utterances.map(\.text).joined(separator: " "))

        var names: [String] = []
        for speaker in speakerNames where !Self.isGenericLabel(speaker) {
            names.append(contentsOf: NotesText.words(speaker).filter { $0.count >= 3 })
        }
        for index in words.indices where capitalised[index] && !starts[index] && words[index].count >= 3 {
            names.append(words[index])
        }
        nameCandidates = Vocabulary(words: names, numbers: [])
    }

    // MARK: After MAP

    func verifyPoints(_ points: [NotesPoint]) -> PointVerdict {
        var verified: [NotesPoint] = []
        var reasons: [DropReason: Int] = [:]
        var downgraded = 0
        var ownerFromSpeaker = 0
        for point in points {
            switch verify(point) {
            case .success(let outcome):
                verified.append(outcome.point)
                if outcome.downgraded { downgraded += 1 }
                if outcome.ownerFromSpeaker { ownerFromSpeaker += 1 }
            case .failure(let reason): reasons[reason, default: 0] += 1
            }
        }
        return PointVerdict(
            verified: verified, dropped: points.count - verified.count, reasons: reasons, downgraded: downgraded,
            ownerFromSpeaker: ownerFromSpeaker)
    }

    /// The verdict after the semantic verifier, by point id. Pure. A missing entry, or one whose source is not
    /// `answered` (malformed, cut off, failed, cancelled), changes nothing (fail closed: a broken runtime never
    /// removes a point). A point answered `weaker` or `unsupported` is REMOVED (`verifierRejected`); its quote
    /// is never shown in its place.
    static func applyingVerifications(
        _ verifications: [String: NotesVerification], to verdict: PointVerdict
    ) -> (verdict: PointVerdict, effect: VerifierEffect) {
        var result = verdict
        var effect = VerifierEffect()
        result.verified = verdict.verified.filter { point in
            guard let verification = verifications[point.id], verification.source == .answered,
                verification.verdict != .supported
            else { return true }
            effect.rejected += 1
            return false
        }
        if effect.rejected > 0 {
            result.dropped += effect.rejected
            result.reasons[.verifierRejected, default: 0] += effect.rejected
        }
        return (result, effect)
    }

    /// How many utterances on each side of the quoted one the verifier sees.
    static let verificationContextUtterances = 2

    /// The verifier's request for a verified point: the claim, the transcript's own quote and the quoted
    /// utterance with `verificationContextUtterances` neighbours on each side, from the transcript the guard
    /// checked against.
    func verificationRequest(for point: NotesPoint, claim: String) -> NotesVerificationRequest {
        var context: [NotesVerificationRequest.Line] = []
        if let center = point.utterance, utterances.indices.contains(center) {
            let low = max(0, center - Self.verificationContextUtterances)
            let high = min(utterances.count - 1, center + Self.verificationContextUtterances)
            context = utterances[low...high].map { .init(speaker: $0.speaker, text: $0.text) }
        }
        return NotesVerificationRequest(kind: point.kind, text: claim, quote: point.quote, context: context)
    }

    private struct Match {
        var range: Range<Int>
        var wholeUtterance: Bool
        /// How many leading quote words the range matches: all of them, or fewer when a literal quote ran on
        /// past a sentence end and only its first sentence was matched.
        var quoteCount: Int
    }

    /// The fewest quote words a match needs unless it is a whole utterance (`quoteTooShort`).
    static let minimumQuoteWords = 3

    private struct Outcome {
        var point: NotesPoint
        var downgraded = false
        /// Set when the person is the speaker, given by the guard (`ownerFromSpeaker`).
        var ownerFromSpeaker = false
    }

    private func verify(_ point: NotesPoint) -> Result<Outcome, DropReason> {
        var point = point
        point.text = Self.plain(point.text)
        point.quote = Self.plain(point.quote)
        guard !point.text.isEmpty else { return .failure(.emptyText) }

        let allQuoteWords = NotesText.words(strippingLinePrefix(point.quote))
        guard !allQuoteWords.isEmpty, let match = find(allQuoteWords, near: point.timeMs) else {
            return .failure(.quoteNotInTranscript)
        }
        // Only the matched part of the quote counts from here on (all of it, unless it was cut at a sentence end).
        let quoteWords = Array(allQuoteWords.prefix(match.quoteCount))
        guard quoteWords.count >= Self.minimumQuoteWords || match.wholeUtterance else {
            return .failure(.quoteTooShort)
        }
        let claimsDecision = point.kind == .decision || point.kind == .task
        if claimsDecision, quoteWords.count == 1 { return .failure(.kindNotSupported) }

        let textLanguage = NotesLanguage.dominant(in: point.text)
        let quoteLanguage = NotesLanguage.dominant(in: point.quote)
        if textLanguage != .unknown, quoteLanguage != .unknown, textLanguage != quoteLanguage {
            return .failure(.languageChanged)
        }

        let covered = Set(match.range.map { wordUtterance[$0] }).sorted()
        let excerpt = self.excerpt(of: match.range)
        var outcome = Outcome(point: point)
        outcome.point.timeMs = utterances[covered[0]].startMs
        outcome.point.speaker = utterances[covered[0]].speaker
        outcome.point.utterance = covered[0]
        outcome.point.sentence = wordSentence[match.range.lowerBound]
        // What is shown as the quote is the transcript's own text.
        outcome.point.quote = excerpt

        // A sentence that is a question is no decision, task or finding. It stays as an open question only when
        // the model wrote it as one.
        if outcome.point.kind != .question, isQuestion(sentence: wordSentence[match.range.lowerBound]) {
            guard outcome.point.text.hasSuffix("?") else { return .failure(.questionNotAFinding) }
            outcome.point.kind = .question
            outcome.downgraded = true
        }
        let vocabulary = Vocabulary(
            words: covered.flatMap { Array(words[utteranceRanges[$0]]) }
                + covered.flatMap { NotesText.words(utterances[$0].speaker) },
            numbers: covered.flatMap {
                NotesText.numberUnits(utterances[$0].text) + NotesText.linkUnits(utterances[$0].text)
            })
        if !Self.isFaithful(outcome.point.text, vocabulary: vocabulary, strictStart: false) {
            return .failure(.unsupportedDetail)
        }
        // A point must not turn a negation around: "nie zatwierdzamy" restated as "zatwierdzono", or the other
        // way round, keeps every word faithful and still flips the meaning.
        if Self.hasNegation(NotesText.words(outcome.point.text)) != Self.hasNegation(quoteWords) {
            return .failure(.negationChanged)
        }
        // A summary point is a fact of the discussion in other words; when most of those words are not the
        // quote's, the sense may have been turned around without anything the checks above see.
        if outcome.point.kind == .summary, Self.driftsFromQuote(outcome.point.text, quote: Array(words[match.range])) {
            return .failure(.driftedFromQuote)
        }

        if outcome.point.kind == .task {
            outcome.point.person = checkedPerson(
                point.person, match: match, speaker: utterances[covered[0]].speaker)
            if outcome.point.person == nil, Self.isEmptyPerson(point.person), covered.count == 1,
                let owner = ownerFromSpeaker(match.range, speaker: utterances[covered[0]].speaker)
            {
                outcome.point.person = owner
                outcome.ownerFromSpeaker = true
            }
            outcome.point.due = checkedDue(point.due, quoteWords: quoteWords)
        } else {
            outcome.point.person = nil
            outcome.point.due = nil
        }
        return .success(outcome)
    }

    /// The original text of the matched words (and the sentence end after them when they end the sentence).
    private func excerpt(of range: Range<Int>) -> String {
        var pieces: [String] = []
        let covered = Set(range.map { wordUtterance[$0] }).sorted()
        for index in covered {
            let inside = range.filter { wordUtterance[$0] == index }
            guard let first = inside.first, let last = inside.last else { continue }
            let characters = Array(utterances[index].text)
            pieces.append(String(characters[charStart[first]..<min(charEnd[last], characters.count)]))
        }
        var text = pieces.joined(separator: " ")
        let sentence = wordSentence[range.upperBound - 1]
        if sentenceRanges[sentence].upperBound == range.upperBound, let end = sentenceTerminators[sentence],
            !text.hasSuffix(String(end))
        {
            text.append(end)
        }
        return Self.plain(text)
    }

    private static let interrogativeOpeners: Set<String> = [
        "czy", "kto", "co", "kiedy", "jak", "jaki", "jaka", "jakie", "dlaczego", "czemu", "gdzie", "ile", "ktory",
        "ktora", "ktore", "skad", "dokad", "po", "who", "what", "when", "how", "why", "where", "which", "do", "does",
        "did", "can", "could", "should", "would", "is", "are", "will", "shall", "have", "has",
    ]
    private static let tagCues: Set<String> = [
        "ok", "okej", "okay", "tak", "prawda", "zgoda", "right", "yes", "agreed", "dobra", "dobrze",
    ]

    /// The sentence ends with a question mark and is either opened by a question word or has no confirming tag
    /// ("..., ok?") at its end: a question, not a statement.
    private func isQuestion(sentence: Int) -> Bool {
        guard sentenceTerminators[sentence] == "?" else { return false }
        let range = sentenceRanges[sentence]
        if Self.interrogativeOpeners.contains(words[range.lowerBound]) { return true }
        return !words[range].suffix(3).contains { Self.tagCues.contains($0) }
    }

    /// The quote without a leading `[mm:ss]` and `Speaker:` the model may have copied along.
    private func strippingLinePrefix(_ quote: String) -> String {
        var text = quote.trimmingCharacters(in: .whitespaces)
        if let match = text.prefixMatch(of: /\[?\d{1,3}:\d{2}(:\d{2})?\]?[ ]*/) {
            text = String(text[match.range.upperBound...])
        }
        for name in speakerNames where text.hasPrefix(name + ":") {
            text = String(text.dropFirst(name.count + 1))
            break
        }
        return text
    }

    /// How many transcript words, in all, a quote may skip between its first and last word (`dha czy chciał`
    /// for the quote `dha chciał`).
    static let maxSkippedTranscriptWords = 2

    /// The first place in the transcript where all quote words follow each other (by `wordsMatch`): a literal
    /// match within one speaker's words (cut at the first sentence end it crosses), one with gaps within one
    /// sentence; with several, the one closest in time to `near`. An exact match (no gaps) wins over one that
    /// skips up to `maxSkippedTranscriptWords` filler words; the first and the last quote word never have a gap
    /// at the edge, and a skipped word is never a negation, a number, a word with a digit or a capitalised name
    /// the quote does not contain.
    private func find(_ quote: [String], near time: Int) -> Match? {
        guard !quote.isEmpty, words.count >= quote.count else { return nil }
        if let exact = find(quote, near: time, skips: 0) { return exact }
        guard quote.count >= 2, Self.maxSkippedTranscriptWords > 0 else { return nil }
        return find(quote, near: time, skips: Self.maxSkippedTranscriptWords)
    }

    private func find(_ quote: [String], near time: Int, skips: Int) -> Match? {
        var best: Match?
        var bestDistance = Int.max
        for start in 0...(words.count - quote.count) where NotesText.wordsMatch(words[start], quote[0]) {
            guard var end = matchEnd(quote, index: 1, after: start, skips: skips, literal: skips == 0) else { continue }
            var quoteCount = quote.count
            if skips > 0 {
                // A match with gaps stays in one sentence.
                guard wordSentence[start] == wordSentence[end - 1] else { continue }
            } else if wordSentence[start] != wordSentence[end - 1] {
                // A literal quote that runs on past a sentence end (within one speaker's words, see `matchEnd`)
                // is matched on its first sentence only; the rest of the quote is ignored. Too short a start
                // is no match.
                end = sentenceRanges[wordSentence[start]].upperBound
                quoteCount = end - start
                guard quoteCount >= Self.minimumQuoteWords else { continue }
            }
            let range = start..<end
            let distance = abs(utterances[wordUtterance[start]].startMs - time)
            if distance < bestDistance {
                bestDistance = distance
                // A match with gaps or a cut one is never a whole utterance: it must not get round `quoteTooShort`.
                best = Match(
                    range: range,
                    wholeUtterance: quoteCount == quote.count && range.count == quote.count && isWhole(range),
                    quoteCount: quoteCount)
            }
        }
        return best
    }

    /// The end (exclusive) of the transcript words matching `quote[index...]` after the word at `position`,
    /// skipping at most `skips` words in all, or nil. A `literal` match may run over a sentence end but stays with
    /// one speaker (`find` cuts it at the first sentence end); any other stays within one sentence.
    private func matchEnd(_ quote: [String], index: Int, after position: Int, skips: Int, literal: Bool) -> Int? {
        if index == quote.count { return position + 1 }
        for gap in 0...skips {
            let next = position + 1 + gap
            guard next < words.count else { return nil }
            if literal {
                guard speaker(of: next) == speaker(of: position) else { return nil }
            } else {
                guard wordSentence[next] == wordSentence[position] else { return nil }
            }
            if gap > 0, !canSkip(position + gap, quote: quote) { return nil }
            if NotesText.wordsMatch(words[next], quote[index]),
                let end = matchEnd(quote, index: index + 1, after: next, skips: skips - gap, literal: literal)
            {
                return end
            }
        }
        return nil
    }

    /// The speaker's label (consecutive utterances of one speaker are one speaker).
    private func speaker(of word: Int) -> String { utterances[wordUtterance[word]].speaker }

    /// Whether the transcript word at `index` may be left out of a quote.
    private func canSkip(_ index: Int, quote: [String]) -> Bool {
        let word = words[index]
        if Self.negations.contains(word) || NotesText.isNumberWord(word) { return false }
        if word.contains(where: \.isNumber) { return false }
        if capitalised[index], !quote.contains(where: { NotesText.wordsMatch($0, word) }) { return false }
        return true
    }

    private func isWhole(_ range: Range<Int>) -> Bool {
        let utterance = wordUtterance[range.lowerBound]
        guard wordUtterance[range.upperBound - 1] == utterance else { return false }
        return utteranceRanges[utterance] == range
    }

    // MARK: Person and date of a task

    private static let personStoplist: Set<String> = [
        "ja", "ty", "on", "ona", "ono", "my", "wy", "oni", "one", "kto", "ktos", "nikt", "wszyscy", "wszystkich",
        "zespol", "team", "everyone", "someone", "somebody", "nobody", "who", "we", "you", "they", "he", "she", "it",
        "tak", "nie", "dobrze", "dzieki", "prosze", "ok", "okej", "pan", "pani", "panie", "this", "that", "the",
    ]
    private static let firstPersonWords: Set<String> = [
        "ja", "zrobie", "wezme", "przygotuje", "wysle", "sprawdze", "zajme", "ogarne", "napisze", "dopisze",
        "poprawie", "zadzwonie", "skontaktuje", "ustale", "przejrze", "przeanalizuje", "dostarcze", "zorganizuje",
        "my", "zrobimy", "wezmiemy", "wyslemy", "zajmiemy",
    ]
    private static let firstPersonPairs: [(String, String)] = [
        ("i", "will"), ("i", "ll"), ("i", "can"), ("i", "ve"), ("i", "take"), ("i", "am"), ("i", "m"), ("let", "me"),
        ("we", "will"), ("we", "ll"),
    ]

    static func isGenericLabel(_ label: String) -> Bool {
        let flat = NotesText.words(label).joined(separator: " ")
        if flat.isEmpty { return true }
        return flat.wholeMatch(
            of: /(speaker|mowca|rozmowca|uczestnik|participant|unknown|nieznany|inni|ja|ty|my|on|ona|i|me|you)( \d+)?/)
            != nil
    }

    /// The plural forms of `firstPersonWords` and `firstPersonPairs`: they say "we", so they name nobody.
    private static let pluralWords: Set<String> = ["my", "zrobimy", "wezmiemy", "wyslemy", "zajmiemy"]
    private static let pluralPairs: [(String, String)] = [("we", "will"), ("we", "ll")]

    private static func isEmptyPerson(_ person: String?) -> Bool {
        guard let person else { return true }
        return plain(person).isEmpty
    }

    /// The speaker owns a task the model gave no person when the quote lies in one utterance, says "I" (a
    /// singular marker, no plural one) and the speaker's label is a real name.
    private func ownerFromSpeaker(_ range: Range<Int>, speaker: String) -> String? {
        guard !Self.isGenericLabel(speaker) else { return nil }
        let quote = Array(words[range])
        let singular = quote.contains { Self.firstPersonWords.contains($0) && !Self.pluralWords.contains($0) }
        var pairSingular = false
        var plural = quote.contains { Self.pluralWords.contains($0) }
        for index in quote.indices.dropLast() {
            let pair = (quote[index], quote[index + 1])
            if Self.pluralPairs.contains(where: { $0 == pair }) {
                plural = true
            } else if Self.firstPersonPairs.contains(where: { $0 == pair }) {
                pairSingular = true
            }
        }
        guard (singular || pairSingular) && !plural else { return nil }
        return speaker
    }

    private func hasFirstPersonMarker(_ range: Range<Int>) -> Bool {
        let quote = Array(words[range])
        if quote.contains(where: { Self.firstPersonWords.contains($0) }) { return true }
        for index in quote.indices.dropLast() {
            if Self.firstPersonPairs.contains(where: { $0.0 == quote[index] && $0.1 == quote[index + 1] }) {
                return true
            }
        }
        return false
    }

    /// The person is a name that stands in the quote (capitalised in the transcript, not a function word). The
    /// speaker's label is accepted only when the quote is in the first person and the label is a real name.
    private func checkedPerson(_ person: String?, match: Match, speaker: String) -> String? {
        guard let person = person.map(Self.plain), !person.isEmpty, !Self.isGenericLabel(person) else { return nil }
        let candidates = match.range.filter { index in
            capitalised[index] && words[index].count >= 3 && !Self.personStoplist.contains(words[index])
                && (!startsSentence[index] || nameCandidates.containsName(words[index]))
        }
        var kept: [String] = []
        for part in person.split(whereSeparator: \.isWhitespace) {
            let word = NotesText.words(String(part)).joined()
            guard word.count >= 3, !Self.personStoplist.contains(word) else { continue }
            if candidates.contains(where: { NotesText.namesMatch(words[$0], word) }) { kept.append(String(part)) }
        }
        if !kept.isEmpty { return kept.joined(separator: " ") }

        guard hasFirstPersonMarker(match.range), !Self.isGenericLabel(speaker) else { return nil }
        let claimed = NotesText.words(person).filter { $0.count >= 3 && !Self.personStoplist.contains($0) }
        let own = NotesText.words(speaker).filter { $0.count >= 3 }
        let same = claimed.contains { name in own.contains { NotesText.namesMatch($0, name) } }
        return same ? speaker : nil
    }

    private func checkedDue(_ due: String?, quoteWords: [String]) -> String? {
        guard let due = due.map(Self.plain), !due.isEmpty else { return nil }
        let dueWords = NotesText.words(due)
        let temporal = dueWords.filter { Temporal.isDateWord($0) }
        let required = temporal.isEmpty ? dueWords.filter { $0.count >= 3 } : temporal
        guard !required.isEmpty else { return nil }
        let allStated = required.allSatisfy { word in quoteWords.contains { NotesText.wordsMatch($0, word) } }
        return allStated ? due : nil
    }

    /// One line of plain text: reasoning blocks and control characters out.
    static func plain(_ text: String) -> String {
        MarkdownText.cleaned(NotesText.clean(text), keepNewlines: false).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    // MARK: Faithfulness of a text

    /// Words a sentence of notes may start with without being a name (normalised).
    private static let sentenceStarters: Set<String> = [
        "zespol", "spotkanie", "ustalono", "zatwierdzono", "omowiono", "uczestnicy", "nalezy", "trzeba", "decyzja",
        "zadanie", "pytanie", "kto", "co", "czy", "jak", "kiedy", "dlaczego", "gdzie", "po", "w", "na", "do", "z", "i",
        "a", "ale", "oraz", "to", "ten", "ta", "te", "jest", "sa", "byl", "bylo", "zostalo", "zostala", "zostal",
        "zostana", "wszyscy", "podczas", "dyskusja", "rozmowa", "uzgodniono", "przyjeto", "postanowiono", "rozmawiano",
        "dotyczylo", "dotyczyla", "przedstawiono", "poruszono", "nastepnie", "ponadto", "takze", "rowniez", "wreszcie",
        "na koniec", "the", "we", "it", "they", "he", "she", "this", "that", "there", "an", "in", "on", "after",
        "during", "meeting", "team", "participants", "decision", "action", "who", "what", "when", "how", "why",
        "where", "is", "are", "will", "should", "can", "do", "does", "please", "also", "then", "next", "first",
        "finally", "overall", "all", "everyone", "someone", "the team", "discussion", "agreed", "decided",
    ]

    /// True when `text` has no digit, number word, weekday or month, and no capitalised word that `vocabulary`
    /// does not have. A sentence starter is capitalised for being first: it passes when it is a common starter
    /// (`strictStart`), or, for a point's text, when it shares four letters with a word of the vocabulary (the
    /// infinitive of the quote's verb).
    static func isFaithful(_ text: String, vocabulary: Vocabulary, strictStart: Bool) -> Bool {
        faithfulnessRefusal(text, vocabulary: vocabulary, strictStart: strictStart) == nil
    }

    /// `isFaithful` with the reason it refuses (the first rule that fails), or nil when the text is faithful.
    static func faithfulnessRefusal(_ text: String, vocabulary: Vocabulary, strictStart: Bool) -> SummaryRefusal? {
        for unit in NotesText.numberUnits(text) + NotesText.linkUnits(text) where !vocabulary.numbers.contains(unit) {
            return .unsupportedNumber
        }
        for token in NotesText.tokens(text) {
            let word = token.word
            if word.contains(where: \.isNumber) { continue }
            if NotesText.isNumberWord(word) {
                if !vocabulary.hasExactly(word) { return .unsupportedNumber }
                continue
            }
            if Temporal.isCalendarWord(word) {
                if !vocabulary.contains(word) { return .unsupportedCalendarWord }
                continue
            }
            guard token.capitalised, word.count >= 2 else { continue }
            if vocabulary.containsName(word) { continue }
            guard token.startsSentence else { return .unsupportedCapitalised }
            if sentenceStarters.contains(word) { continue }
            if !strictStart, word.count >= 4, vocabulary.sharesStem(word) { continue }
            return .unsupportedSentenceStart
        }
        return nil
    }

    // MARK: Drift of a summary point from its quote

    /// A summary point keeps its text only when at least 3 of every 5 of its content words are words of the
    /// quote (`quoteCoverage`). Chosen on the reversed key points of a real meeting (coverage 0 to 0.5) and the
    /// faithful paraphrases of the corpus (0.67 and more); see `NotesDriftTests`.
    static let minimumQuoteCoverage = (covered: 3, of: 5)

    /// Function words of four letters or more, and words a note uses to frame what was said ("Mówca mówi,
    /// że…"): they say nothing about the fact, so they are not counted. Shorter words are not counted at all.
    private static let notContentWords: Set<String> = [
        "jest", "przez", "przed", "ktory", "ktora", "ktore", "ktorzy", "ktorych", "ktorym", "ktorej", "tego",
        "temu", "tych", "tymi", "jako", "oraz", "takze", "rowniez", "bedzie", "beda", "byla", "byly", "byli",
        "zostanie", "zostaly", "zostali", "mozna", "moze", "jego", "nich", "nimi", "swoj", "swoja", "swoje",
        "swoich", "ktos", "wszystko", "wszyscy", "wszystkie", "tylko", "jeszcze", "wiec", "jednak", "albo", "czyli",
        "gdyz", "poniewaz", "zeby", "kiedy", "gdzie", "podczas", "miedzy", "wobec", "wedlug", "dzieki", "poza",
        "tutaj", "teraz", "mowca", "mowi", "mowil", "mowila", "mowia", "rozmowca", "uczestnik", "uwaza",
        "stwierdza", "stwierdzil", "zauwaza", "podkresla", "wspomina", "wspomnial", "twierdzi", "mowa", "temat",
        "tematu", "kwestia", "kwestii", "that", "this", "with", "from", "have", "will", "would", "should", "could",
        "they", "them", "their", "there", "what", "which", "about", "into", "than", "then", "been", "were", "also",
        "only", "some", "very", "just", "does", "each", "says", "said", "speaker", "mentions",
    ]

    /// How many of the content words of `text` (words of at least four letters that are not in
    /// `notContentWords` or `sentenceStarters`, each counted once) are words of `quote`, by
    /// `NotesText.wordsMatch` or `NotesText.sharesStem`.
    static func quoteCoverage(of text: String, quote: [String]) -> (covered: Int, total: Int) {
        var seen = Set<String>()
        var covered = 0
        for word in NotesText.words(text)
        where word.count >= 4 && !notContentWords.contains(word) && !sentenceStarters.contains(word) {
            guard seen.insert(word).inserted else { continue }
            if quote.contains(where: { NotesText.wordsMatch($0, word) || NotesText.sharesStem($0, word) }) {
                covered += 1
            }
        }
        return (covered, seen.count)
    }

    /// The text has content words and fewer than `minimumQuoteCoverage` of them are the quote's.
    static func driftsFromQuote(_ text: String, quote: [String]) -> Bool {
        let coverage = quoteCoverage(of: text, quote: quote)
        return coverage.total > 0
            && coverage.covered * minimumQuoteCoverage.of < coverage.total * minimumQuoteCoverage.covered
    }

    // MARK: After REDUCE

    /// Checks the structure REDUCE returned against the verified points (the output of `verifyPoints`). A point
    /// the model left out is added back to its section unless a near-duplicate is listed there: nothing that
    /// was verified disappears because the model forgot it.
    func verifyReduce(_ output: NotesReduceOutput, points: [NotesPoint]) -> ReduceVerdict {
        var audit: ReduceAudit?
        return verifyReduce(output, points: points, audit: &audit)
    }

    /// Why `summaryIsFaithful` refuses a paragraph: the rule that failed, never any text.
    enum SummaryRefusal: String, Sendable, Codable {
        case tooLong, tooManyWords, languageChanged, negation
        case unsupportedNumber, unsupportedCalendarWord, unsupportedCapitalised, unsupportedSentenceStart
    }

    /// What `verifyReduce` did with every id and point, for `NotesTrace` (ids, kinds and counts only).
    struct ReduceAudit: Equatable, Sendable {
        enum SummaryOrigin: String, Sendable {
            /// The model's paragraph passed `summaryIsFaithful`.
            case model
            /// The model's paragraph was refused as a whole; the sentences that each pass the same checks
            /// are kept in their order (at least two, at least half of the words).
            case salvagedSentences
            /// The model's paragraph was refused and nothing could be salvaged: there is no summary.
            case refused
            /// The model gave no paragraph (or REDUCE failed): there is no summary.
            case absent
        }

        /// Points added back to their section.
        var backfilled: Set<String> = []
        /// Points not added back, with the point in their section that near-duplicates them.
        var nearDuplicateOf: [String: String] = [:]
        /// Verified points the model listed in another kind's section: the kinds of those sections.
        var misfiled: [String: [NotesPointKind]] = [:]
        /// Listed ids that are no verified point.
        var unknownIDs = 0
        /// Ids listed again in their own section (kept once).
        var repeatedIDs = 0
        var summaryOrigin = SummaryOrigin.absent
        /// Why the model's paragraph was refused (`refused`, `salvagedSentences`), else nil.
        var summaryRefusal: SummaryRefusal?
        /// Summary points whose whole text is already a sentence of the model's (or salvaged) paragraph, so
        /// they are not listed again among the key points.
        var inModelParagraph: Set<String> = []
        /// Summary points REDUCE chose that were not shown: a question, a near twin of one listed, or over the
        /// limit (`NotesGuard.maxKeyPoints`).
        var findingsOverLimit: Set<String> = []
        /// Questions REDUCE listed that were not shown because of the limit (`NotesGuard.maxQuestions`).
        var questionsOverLimit: Set<String> = []
    }

    /// `verifyReduce` with its audit; the verdict is the one `verifyReduce` returns.
    func auditedVerifyReduce(
        _ output: NotesReduceOutput, points: [NotesPoint]
    ) -> (verdict: ReduceVerdict, audit: ReduceAudit) {
        var audit: ReduceAudit? = ReduceAudit()
        let verdict = verifyReduce(output, points: points, audit: &audit)
        return (verdict, audit ?? ReduceAudit())
    }

    private func verifyReduce(
        _ output: NotesReduceOutput, points: [NotesPoint], audit: inout ReduceAudit?
    ) -> ReduceVerdict {
        let byID = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rejected = 0
        var trail = audit

        func section(_ ids: [String], kind: NotesPointKind) -> [NotesPoint] {
            var seen = Set<String>()
            var result: [NotesPoint] = []
            for id in ids {
                guard let point = byID[id], point.kind == kind else {
                    rejected += 1
                    if byID[id] == nil {
                        trail?.unknownIDs += 1
                    } else {
                        trail?.misfiled[id, default: []].append(kind)
                    }
                    continue
                }
                if seen.insert(id).inserted {
                    result.append(point)
                } else {
                    trail?.repeatedIDs += 1
                }
            }
            return result
        }

        var decisions = section(output.decisions, kind: .decision)
        var tasks = section(output.tasks, kind: .task)
        var questions = section(output.questions, kind: .question)

        let listed = Set((decisions + tasks + questions).map(\.id))
        var backfilled = 0
        // Decisions and tasks are rare and each one matters, so one REDUCE forgot is added back. Questions and
        // findings are not: what REDUCE did not choose stays out.
        func fill(_ list: inout [NotesPoint], kind: NotesPointKind) {
            for point in points where point.kind == kind && !listed.contains(point.id) {
                if let twin = list.first(where: { Self.nearDuplicate($0, point) }) {
                    trail?.nearDuplicateOf[point.id] = twin.id
                    continue
                }
                list.append(point)
                backfilled += 1
                trail?.backfilled.insert(point.id)
            }
        }
        fill(&decisions, kind: .decision)
        fill(&tasks, kind: .task)
        if questions.count > Self.maxQuestions {
            for point in questions[Self.maxQuestions...] { trail?.questionsOverLimit.insert(point.id) }
            questions = Array(questions.prefix(Self.maxQuestions))
        }

        var summary: String?
        var replaced = false
        if let proposed = output.summary.map(Self.plain), !proposed.isEmpty, !points.isEmpty {
            if let refusal = summaryRefusal(proposed, points: points) {
                replaced = true
                trail?.summaryRefusal = refusal
                if let salvaged = salvagedSentences(of: proposed, points: points) {
                    summary = salvaged
                    trail?.summaryOrigin = .salvagedSentences
                } else {
                    trail?.summaryOrigin = .refused
                }
            } else {
                summary = proposed
                trail?.summaryOrigin = .model
            }
        }
        // The paragraph is free text: a finding is left out only when its whole text is one of the paragraph's
        // sentences, not a part of a longer one ("Ewa przygotuje umowę" inside "Czy Ewa przygotuje umowę, nie
        // ustalono.").
        var inParagraph = Set<String>()
        if let text = summary {
            let sentences = Set(Self.sentences(of: text))
            for point in points where point.kind == .summary && Self.isOneOf(sentences, point) {
                inParagraph.insert(point.id)
                trail?.inModelParagraph.insert(point.id)
            }
        }

        // The findings are the ones REDUCE chose, in its order, never a question, a near twin of one listed or a
        // sentence of the paragraph, and at most `maxKeyPoints`.
        var keyPoints: [NotesPoint] = []
        var seenKeys = Set<String>()
        let saidInParagraph = points.filter { inParagraph.contains($0.id) }
        for id in output.keyPoints {
            guard let point = byID[id], point.kind == .summary else {
                rejected += 1
                if byID[id] == nil {
                    trail?.unknownIDs += 1
                } else {
                    trail?.misfiled[id, default: []].append(.summary)
                }
                continue
            }
            guard seenKeys.insert(id).inserted else {
                trail?.repeatedIDs += 1
                continue
            }
            if inParagraph.contains(id) { continue }
            if point.text.hasSuffix("?") {
                trail?.findingsOverLimit.insert(id)
                continue
            }
            if let twin = keyPoints.first(where: { Self.nearDuplicate($0, point) })
                ?? saidInParagraph.first(where: { Self.nearDuplicate($0, point) })
            {
                trail?.nearDuplicateOf[id] = twin.id
                continue
            }
            if keyPoints.count >= Self.maxKeyPoints {
                trail?.findingsOverLimit.insert(id)
                continue
            }
            keyPoints.append(point)
        }
        audit = trail
        return ReduceVerdict(
            decisions: decisions, tasks: tasks, questions: questions, summary: summary, summaryReplaced: replaced,
            rejectedIDs: rejected, backfilled: backfilled, keyPoints: keyPoints)
    }

    /// The most findings ("Topics discussed") the notes show, and the most open questions.
    static let maxKeyPoints = 10
    static let maxQuestions = 5

    /// The point's whole text is one sentence and equals one of `sentences` (a free-text paragraph's sentences).
    private static func isOneOf(_ sentences: Set<String>, _ point: NotesPoint) -> Bool {
        let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = NotesText.firstSentence(point.text)
        return !sentence.isEmpty && sentence == text && sentences.contains(sentence)
    }

    /// The same utterance and sentence, or quotes that share most of their words.
    static func nearDuplicate(_ first: NotesPoint, _ second: NotesPoint) -> Bool {
        if first.kind != second.kind { return false }
        if let u1 = first.utterance, let u2 = second.utterance, let s1 = first.sentence, let s2 = second.sentence,
            u1 == u2, s1 == s2
        {
            return true
        }
        let a = Set(NotesText.words(first.quote))
        let b = Set(NotesText.words(second.quote))
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.7
    }

    static let maxSummaryLength = 1500
    static let maxSummaryWords = 160

    private static func hasNegation(_ words: [String]) -> Bool {
        words.contains { negations.contains($0) }
    }

    private static let negations: Set<String> = [
        "nie", "nigdy", "nikt", "nic", "zaden", "zadna", "zadne", "not", "no", "never", "nobody", "nothing", "none",
        "cannot", "without",
    ]

    /// The model's paragraph passes only when ALL of these hold; otherwise the caller composes it in code:
    /// - at most 1500 characters and 160 words, in the language of the transcript;
    /// - every number written with digits (a decimal, a time or a date counts as one unit: `3.5` is not `5.3`)
    ///   is in the verified material (the quotes, the texts of the verified points, the person and due date of
    ///   the tasks, the speakers' names);
    /// - every spelled-out number (Polish or English, compared exactly), weekday and month is in it;
    /// - every capitalised word, the first word of a sentence included, is in it or is one of a short list of
    ///   common sentence starters;
    /// - a negation appears only if some verified quote or text has one.
    /// What this cannot catch: a paraphrase that reverses a fact without any of the above ("zatwierdzono" for
    /// "odrzucono"), or an invented lowercase fact. That is why the paragraph is the only free model text in
    /// the notes, and why its failure costs nothing (the composed summary takes its place).
    func summaryIsFaithful(_ summary: String, points: [NotesPoint]) -> Bool {
        summaryRefusal(summary, points: points) == nil
    }

    /// `summaryIsFaithful` with the first rule that fails, or nil when the paragraph passes.
    func summaryRefusal(_ summary: String, points: [NotesPoint]) -> SummaryRefusal? {
        if summary.count > Self.maxSummaryLength { return .tooLong }
        if summary.split(whereSeparator: \.isWhitespace).count > Self.maxSummaryWords { return .tooManyWords }
        return textRefusal(summary, material: summaryMaterial(points: points))
    }

    /// What a summary is checked against: the vocabulary of the verified material and whether it has a negation.
    private struct SummaryMaterial {
        var vocabulary: Vocabulary
        var hasNegation: Bool
    }

    private func summaryMaterial(points: [NotesPoint]) -> SummaryMaterial {
        var corpus: [String] = []
        var numbers: [String] = []
        for point in points {
            for field in [point.quote, point.text, point.person ?? "", point.due ?? ""] where !field.isEmpty {
                corpus.append(contentsOf: NotesText.words(field))
                numbers.append(contentsOf: NotesText.numberUnits(field) + NotesText.linkUnits(field))
            }
        }
        for speaker in speakerNames {
            corpus.append(contentsOf: NotesText.words(speaker))
            numbers.append(contentsOf: NotesText.numberUnits(speaker))
        }
        return SummaryMaterial(
            vocabulary: Vocabulary(words: corpus, numbers: numbers),
            hasNegation: corpus.contains(where: { Self.negations.contains($0) }))
    }

    /// The language, negation and name/number checks of `summaryRefusal` (the length limits are not part of it).
    private func textRefusal(_ text: String, material: SummaryMaterial) -> SummaryRefusal? {
        let textLanguage = NotesLanguage.dominant(in: text)
        if language != .unknown, textLanguage != .unknown, textLanguage != language { return .languageChanged }
        if NotesText.words(text).contains(where: { Self.negations.contains($0) }), !material.hasNegation {
            return .negation
        }
        return Self.faithfulnessRefusal(text, vocabulary: material.vocabulary, strictStart: true)
    }

    /// The sentences of a refused paragraph that each pass the checks of `summaryRefusal` on their own, in their
    /// order. Nothing is relaxed: the same material, language and negation rules and the strict sentence starts
    /// apply to every sentence, and the result must pass `summaryRefusal` as a whole. It is used only when at
    /// least two sentences and at least half of the words of the paragraph remain; otherwise nil.
    func salvagedSentences(of paragraph: String, points: [NotesPoint]) -> String? {
        let sentences = Self.sentences(of: paragraph)
        guard sentences.count >= 2 else { return nil }
        let material = summaryMaterial(points: points)
        let kept = sentences.filter { textRefusal($0, material: material) == nil }
        guard kept.count >= 2 else { return nil }
        func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
        guard wordCount(kept.joined(separator: " ")) * 2 >= wordCount(paragraph) else { return nil }
        let joined = kept.joined(separator: " ")
        return summaryRefusal(joined, points: points) == nil ? joined : nil
    }

    /// Sentences ending in `.`, `!` or `?` followed by white space or the end (the rule of `firstSentence`, so
    /// `3.5` stays whole).
    static func sentences(of text: String) -> [String] {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []
        var start = flat.startIndex
        var index = flat.startIndex
        while index < flat.endIndex {
            let next = flat.index(after: index)
            if ".!?".contains(flat[index]), next == flat.endIndex || flat[next].isWhitespace {
                let sentence = flat[start..<next].trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append(sentence) }
                start = next
            }
            index = next
        }
        let rest = flat[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// Words grouped by their first two letters, so a lookup stays cheap for a long list.
    struct Vocabulary: Sendable {
        private var groups: [String: [String]] = [:]
        private var exact: Set<String> = []
        let numbers: Set<String>

        init(words: [String], numbers: [String]) {
            for word in words {
                groups[String(word.prefix(2)), default: []].append(word)
                exact.insert(word)
            }
            self.numbers = Set(numbers)
        }

        func hasExactly(_ word: String) -> Bool { exact.contains(word) }

        func contains(_ word: String) -> Bool {
            exact.contains(word)
                || (groups[String(word.prefix(2))]?.contains { NotesText.wordsMatch($0, word) } ?? false)
        }

        func containsName(_ word: String) -> Bool {
            exact.contains(word)
                || (groups[String(word.prefix(2))]?.contains {
                    NotesText.namesMatch($0, word) || NotesText.wordsMatch($0, word)
                } ?? false)
        }

        /// A word that begins like `word` (four letters): the verb of the quote in another form.
        func sharesStem(_ word: String) -> Bool {
            let stem = word.prefix(4)
            return groups[String(word.prefix(2))]?.contains { $0.hasPrefix(stem) } ?? false
        }
    }
}

/// Weekdays and months, by the forms they take in a sentence, and the words that name a relative date.
enum Temporal {
    private static let groups: [String: String] = {
        let table: [[String]] = [
            ["poniedzialek", "poniedzialku", "poniedzialkiem", "poniedzialki", "poniedzialkow", "poniedzialkach"],
            ["wtorek", "wtorku", "wtorkiem", "wtorki", "wtorkow", "wtorkach"],
            ["sroda", "srode", "srody", "srodzie", "srodami", "srodach", "srodzien"],
            ["czwartek", "czwartku", "czwartkiem", "czwartki", "czwartkow", "czwartkach"],
            ["piatek", "piatku", "piatkiem", "piatki", "piatkow", "piatkach"],
            ["sobota", "sobote", "soboty", "sobocie", "sobotach"],
            ["niedziela", "niedziele", "niedzieli", "niedzielach"],
            ["styczen", "stycznia", "styczniu"], ["luty", "lutego", "lutym"], ["marzec", "marca", "marcu"],
            ["kwiecien", "kwietnia", "kwietniu"], ["maj", "maja", "maju"], ["czerwiec", "czerwca", "czerwcu"],
            ["lipiec", "lipca", "lipcu"], ["sierpien", "sierpnia", "sierpniu"],
            ["wrzesien", "wrzesnia", "wrzesniu"], ["pazdziernik", "pazdziernika", "pazdzierniku"],
            ["listopad", "listopada", "listopadzie"], ["grudzien", "grudnia", "grudniu"],
            ["monday", "mondays"], ["tuesday", "tuesdays"], ["wednesday", "wednesdays"], ["thursday", "thursdays"],
            ["friday", "fridays"], ["saturday", "saturdays"], ["sunday", "sundays"], ["january"], ["february"],
            ["march"], ["april"], ["june"], ["july"], ["august"], ["september"], ["october"], ["november"],
            ["december"],
        ]
        var result: [String: String] = [:]
        for forms in table { for form in forms { result[form] = forms[0] } }
        return result
    }()

    private static let relative = [
        "jutro", "dzis", "dzisiaj", "pojutrze", "wczoraj", "tomorrow", "today", "tonight", "yesterday",
        "tydzien", "tygodni", "miesiac", "miesiec", "kwartal", "week", "month", "quarter", "eod", "eow", "asap",
        "weekend", "przyszl", "nastepn", "next",
    ]

    /// The weekday or month a form belongs to (`piatku` → `piatek`), `nil` for any other word.
    static func group(of word: String) -> String? {
        groups[word]
    }

    /// A weekday or a month name.
    static func isCalendarWord(_ word: String) -> Bool {
        groups[word] != nil
    }

    /// Anything a due date is made of: a number, a weekday, a month, a relative day or period.
    static func isDateWord(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || isCalendarWord(word)
            || relative.contains { word.hasPrefix($0) && word.count <= $0.count + 4 }
    }
}

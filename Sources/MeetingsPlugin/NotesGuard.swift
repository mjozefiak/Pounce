import Foundation
import PounceCore

/// The structure REDUCE returns: the ids of the points for each section and a paragraph. Nothing in it is
/// trusted yet; `NotesGuard.verifyReduce` checks the ids and the paragraph.
struct NotesReduceOutput: Equatable, Sendable {
    var decisions: [String] = []
    var tasks: [String] = []
    var questions: [String] = []
    var summary: String?
}

/// The defence against a model that invents (spec: Architecture → Notatki, pkt 4). Pure; it runs twice:
/// after MAP on the points (`verifyPoints`) and after REDUCE on the structure (`verifyReduce`).
///
/// - A point is kept only when its quote is in the transcript. The comparison is on normalised words
///   (`TextNormalizer`), and a word may differ by a short ending (`NotesText.wordsMatch`, Polish inflection).
/// - A task keeps its person only when the person is named in the quote or is the speaker of the quoted
///   utterance, and its due date only when the date or weekday is in the quote. Otherwise the task stays without
///   them. Nothing is guessed.
/// - Reduce: an id that is not a verified point is dropped; the summary may not contain a name, number, date or
///   weekday that no verified point has, and may not change language; on a violation the summary is replaced by
///   the first sentences of the points.
struct NotesGuard: Sendable {
    enum DropReason: String, Error, Sendable, CaseIterable {
        case emptyText, quoteTooShort, quoteNotInTranscript, languageChanged
    }

    struct PointVerdict: Equatable, Sendable {
        var verified: [NotesPoint]
        var dropped: Int
        var reasons: [DropReason: Int]
    }

    struct ReduceVerdict: Equatable, Sendable {
        var decisions: [NotesPoint]
        var tasks: [NotesPoint]
        var questions: [NotesPoint]
        var summary: String?
        /// The model's paragraph was refused and `summary` is composed from the points.
        var summaryReplaced: Bool
        /// Ids the model returned that are unknown or in the wrong section.
        var rejectedIDs: Int

        var hasItems: Bool { !(decisions.isEmpty && tasks.isEmpty && questions.isEmpty) }
    }

    private let utterances: [NotesUtterance]
    private let words: [String]
    private let wordUtterance: [Int]
    private let speakerNames: [String]
    /// The dominant language of the whole transcript.
    let language: NotesLanguage

    init(utterances: [NotesUtterance]) {
        self.utterances = utterances
        var words: [String] = []
        var owner: [Int] = []
        for (index, utterance) in utterances.enumerated() {
            let these = NotesText.words(utterance.text)
            words.append(contentsOf: these)
            owner.append(contentsOf: Array(repeating: index, count: these.count))
        }
        self.words = words
        wordUtterance = owner
        speakerNames = Array(Set(utterances.map(\.speaker))).sorted()
        language = NotesLanguage.dominant(in: utterances.map(\.text).joined(separator: " "))
    }

    // MARK: After MAP

    func verifyPoints(_ points: [NotesPoint]) -> PointVerdict {
        var verified: [NotesPoint] = []
        var reasons: [DropReason: Int] = [:]
        for point in points {
            switch verify(point) {
            case .success(let checked): verified.append(checked)
            case .failure(let reason): reasons[reason, default: 0] += 1
            }
        }
        return PointVerdict(verified: verified, dropped: points.count - verified.count, reasons: reasons)
    }

    private struct Match {
        var range: Range<Int>
        var wholeUtterance: Bool
    }

    private func verify(_ point: NotesPoint) -> Result<NotesPoint, DropReason> {
        var point = point
        point.text = Self.plain(point.text)
        point.quote = Self.plain(point.quote)
        guard !point.text.isEmpty else { return .failure(.emptyText) }

        let quoteWords = NotesText.words(strippingLinePrefix(point.quote))
        guard !quoteWords.isEmpty, let match = find(quoteWords, near: point.timeMs) else {
            return .failure(.quoteNotInTranscript)
        }
        guard quoteWords.count >= 3 || match.wholeUtterance else { return .failure(.quoteTooShort) }

        let textLanguage = NotesLanguage.dominant(in: point.text)
        let quoteLanguage = NotesLanguage.dominant(in: point.quote)
        if textLanguage != .unknown, quoteLanguage != .unknown, textLanguage != quoteLanguage {
            return .failure(.languageChanged)
        }

        let covered = Set(match.range.map { wordUtterance[$0] }).sorted()
        point.timeMs = utterances[covered[0]].startMs
        point.speaker = utterances[covered[0]].speaker
        if point.kind == .task {
            point.person = checkedPerson(
                point.person, quoteWords: quoteWords, speakers: covered.map { utterances[$0].speaker })
            point.due = checkedDue(point.due, quoteWords: quoteWords)
        } else {
            point.person = nil
            point.due = nil
        }
        return .success(point)
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

    /// The first place in the transcript where all quote words follow each other (by `wordsMatch`); with several,
    /// the one closest in time to `near`.
    private func find(_ quote: [String], near time: Int) -> Match? {
        guard !quote.isEmpty, words.count >= quote.count else { return nil }
        var best: Match?
        var bestDistance = Int.max
        for start in 0...(words.count - quote.count) where NotesText.wordsMatch(words[start], quote[0]) {
            var index = 1
            while index < quote.count, NotesText.wordsMatch(words[start + index], quote[index]) { index += 1 }
            guard index == quote.count else { continue }
            let range = start..<(start + quote.count)
            let distance = abs(utterances[wordUtterance[start]].startMs - time)
            if distance < bestDistance {
                bestDistance = distance
                best = Match(range: range, wholeUtterance: isWhole(range))
            }
        }
        return best
    }

    private func isWhole(_ range: Range<Int>) -> Bool {
        let utterance = wordUtterance[range.lowerBound]
        guard wordUtterance[range.upperBound - 1] == utterance else { return false }
        let all = wordUtterance.indices.filter { wordUtterance[$0] == utterance }
        return all.first == range.lowerBound && all.last == range.upperBound - 1
    }

    private func checkedPerson(_ person: String?, quoteWords: [String], speakers: [String]) -> String? {
        guard let person = person.map(Self.plain), !person.isEmpty else { return nil }
        let nameWords = NotesText.words(person).filter { $0.count >= 2 }
        guard !nameWords.isEmpty else { return nil }
        let speakerWords = speakers.flatMap(NotesText.words)
        let stated = nameWords.contains { name in
            quoteWords.contains { NotesText.wordsMatch($0, name) }
                || speakerWords.contains { NotesText.wordsMatch($0, name) }
        }
        return stated ? person : nil
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
        MarkdownExporter.cleaned(NotesText.clean(text), keepNewlines: false).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    // MARK: After REDUCE

    /// Checks the structure REDUCE returned against the verified points. Never throws away a verified point on
    /// its own: a point the model left out was merged into another one as a duplicate.
    func verifyReduce(_ output: NotesReduceOutput, points: [NotesPoint]) -> ReduceVerdict {
        let byID = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rejected = 0

        func section(_ ids: [String], kind: NotesPointKind) -> [NotesPoint] {
            var seen = Set<String>()
            var result: [NotesPoint] = []
            for id in ids {
                guard let point = byID[id], point.kind == kind else {
                    rejected += 1
                    continue
                }
                if seen.insert(id).inserted { result.append(point) }
            }
            return result
        }

        let decisions = section(output.decisions, kind: .decision)
        let tasks = section(output.tasks, kind: .task)
        let questions = section(output.questions, kind: .question)

        var summary: String?
        var replaced = false
        if let proposed = output.summary.map(Self.plain), !proposed.isEmpty, !points.isEmpty {
            if summaryIsFaithful(proposed, points: points) {
                summary = proposed
            } else {
                replaced = true
            }
        }
        if summary == nil {
            summary = Self.composedSummary(from: points, decisions: decisions, tasks: tasks, questions: questions)
        }
        return ReduceVerdict(
            decisions: decisions, tasks: tasks, questions: questions, summary: summary, summaryReplaced: replaced,
            rejectedIDs: rejected)
    }

    static let maxSummaryLength = 1500

    /// The summary has only names, numbers and dates that the verified points have, and the transcript's language.
    func summaryIsFaithful(_ summary: String, points: [NotesPoint]) -> Bool {
        if summary.count > Self.maxSummaryLength { return false }
        let summaryLanguage = NotesLanguage.dominant(in: summary)
        if language != .unknown, summaryLanguage != .unknown, summaryLanguage != language { return false }

        var corpus: [String] = []
        for point in points {
            corpus.append(contentsOf: NotesText.words(point.text + " " + point.quote))
            if let person = point.person { corpus.append(contentsOf: NotesText.words(person)) }
            if let due = point.due { corpus.append(contentsOf: NotesText.words(due)) }
        }
        for speaker in speakerNames { corpus.append(contentsOf: NotesText.words(speaker)) }
        let known = WordIndex(corpus)

        for token in Self.tokens(of: summary) {
            let normalized = TextNormalizer.normalize(token.text)
            guard !normalized.isEmpty else { continue }
            let hasDigit = normalized.contains(where: \.isNumber)
            let isName = !token.startsSentence && (token.text.first?.isUppercase ?? false)
            let isDate = Temporal.isCalendarWord(normalized)
            if hasDigit || isName || isDate, !known.contains(normalized) { return false }
        }
        return true
    }

    private struct Token {
        var text: String
        var startsSentence: Bool
    }

    private static func tokens(of text: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var startsSentence = true
        var nextStartsSentence = true
        func flush() {
            if !current.isEmpty {
                result.append(Token(text: current, startsSentence: startsSentence))
                current = ""
                nextStartsSentence = false
            }
        }
        for character in text {
            if character.isLetter || character.isNumber {
                if current.isEmpty { startsSentence = nextStartsSentence }
                current.append(character)
            } else {
                flush()
                if ".!?:;\n".contains(character) { nextStartsSentence = true }
            }
        }
        flush()
        return result
    }

    /// The first sentences of the points, used when the model's paragraph is missing or refused.
    static func composedSummary(
        from points: [NotesPoint], decisions: [NotesPoint], tasks: [NotesPoint], questions: [NotesPoint]
    ) -> String? {
        var sources = points.filter { $0.kind == .summary }.sorted { $0.timeMs < $1.timeMs }
        if sources.isEmpty { sources = decisions + tasks + questions }
        var sentences: [String] = []
        for point in sources.prefix(4) {
            let sentence = NotesText.firstSentence(point.text)
            if !sentence.isEmpty {
                sentences.append(
                    sentence.hasSuffix(".") || sentence.hasSuffix("!") || sentence.hasSuffix("?")
                        ? sentence : sentence + ".")
            }
        }
        let joined = sentences.joined(separator: " ")
        return joined.isEmpty ? nil : NotesText.truncated(joined, limit: maxSummaryLength)
    }

    /// Words grouped by their first four letters, so `contains` stays cheap for a long list.
    private struct WordIndex {
        private var groups: [String: [String]] = [:]

        init(_ words: [String]) {
            for word in words { groups[String(word.prefix(4)), default: []].append(word) }
        }

        func contains(_ word: String) -> Bool {
            groups[String(word.prefix(4))]?.contains { NotesText.wordsMatch($0, word) } ?? false
        }
    }
}

/// Words that name a date. Normalised stems (no diacritics).
enum Temporal {
    private static let calendar = [
        "poniedzial", "wtorek", "wtork", "srod", "czwart", "piat", "sobot", "niedziel",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "styczn", "styczen", "luty", "lutego", "marz", "kwiet", "maj", "czerw", "lip", "sierp", "wrzes", "pazdz",
        "listopad", "grud", "january", "february", "march", "april", "june", "july", "august", "september",
        "october", "november", "december",
    ]
    private static let relative = [
        "jutro", "dzis", "dzisiaj", "pojutrze", "wczoraj", "tomorrow", "today", "tonight", "yesterday",
        "tydzien", "tygodni", "miesiac", "miesiec", "kwartal", "week", "month", "quarter", "eod", "eow", "asap",
        "weekend", "poniedzialku", "przyszl", "nastepn", "next",
    ]

    /// A weekday or a month name.
    static func isCalendarWord(_ word: String) -> Bool {
        calendar.contains { word.hasPrefix($0) && word.count <= $0.count + 4 }
    }

    /// Anything a due date is made of: a number, a weekday, a month, a relative day or period.
    static func isDateWord(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || isCalendarWord(word)
            || relative.contains { word.hasPrefix($0) && word.count <= $0.count + 4 }
    }
}

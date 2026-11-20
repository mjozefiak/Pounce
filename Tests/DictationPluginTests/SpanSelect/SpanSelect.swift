import Foundation

@testable import DictationPlugin
@testable import LintelSpeech

/// Measurement prototype of "span selection" for removing dictated self-corrections (PR measurement note in
/// `docs/decisions/0013-span-selection-measurement.md`). Nothing here is product code: the model never rewrites
/// text. It gets the words before a spoken retraction marker, numbered, and answers ONE number (the first word
/// that the marker takes back) or `none`. The code builds the result as the input without `[start...marker]`,
/// so the result is always the input's words in the input's order, minus one contiguous span that ends at the
/// marker.
enum SpanSelect {
    struct Marker: Equatable {
        /// Index of the marker's first word and the index after its last word.
        let start: Int
        let end: Int
    }

    enum Decision: Equatable {
        case none
        /// Index of the first word of the removed span.
        case start(Int)
    }

    /// Everything one decision needs.
    struct Query {
        let words: [String]
        let marker: Marker
        /// Allowed starts (word indices), the `n` words before the marker.
        let window: Range<Int>
        let polish: Bool
    }

    // MARK: words and markers

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Lower-cased letters, digits and apostrophes of a word, as `FormatterGuard.tokens` keeps them.
    static func key(_ word: String) -> String {
        FormatterGuard.tokens(word).joined()
    }

    /// The first retraction marker at or after `index` (the longest one at the earliest word).
    static func marker(in keys: [String], from index: Int = 0) -> Marker? {
        guard index < keys.count else { return nil }
        for position in index..<keys.count {
            let lengths = FormatterGuard.retractionMarkers.compactMap { marker -> Int? in
                position + marker.count <= keys.count && Array(keys[position..<(position + marker.count)]) == marker
                    ? marker.count : nil
            }
            if let longest = lengths.max() { return Marker(start: position, end: position + longest) }
        }
        return nil
    }

    /// The input without `[start..<marker.end]`.
    static func apply(_ words: [String], marker: Marker, decision: Decision) -> [String] {
        switch decision {
        case .none: return words
        case .start(let start): return Array(words[..<start]) + Array(words[marker.end...])
        }
    }

    static func window(before marker: Marker, limit: Int) -> Range<Int> {
        max(0, marker.start - limit)..<marker.start
    }

    // MARK: the negation rule

    /// "A negation in the removed span that is absent after the marker means nothing": a cut that drops a
    /// negation without leaving one behind can turn the sentence round, so the decision is replaced by `none`.
    static func negationRule(_ decision: Decision, in query: Query) -> Decision {
        guard case .start(let start) = decision else { return decision }
        let keys = query.words.map(key)
        let removed = keys[start..<query.marker.start].contains { FormatterGuard.negates($0, polish: query.polish) }
        guard removed else { return decision }
        let kept = keys[query.marker.end...].contains { FormatterGuard.negates($0, polish: query.polish) }
        return kept ? decision : .none
    }

    // MARK: prompt, grammar, parsing

    static let system = """
        You mark a spoken self-correction in a dictated text. The speaker said a correction marker, written \
        between << and >>. The words before it are numbered. If the marker takes back some words just before \
        it, answer the number of the FIRST word that is taken back: the taken-back words run from that word up \
        to the marker, and the speaker repeats them in better form right after the marker. Start at the word \
        that the new version replaces (a changed number, name or place; a preposition or word of the same \
        phrase that the speaker says again). If the marker is ordinary content of the sentence, a question, a \
        doubt, a request, or you are not sure, answer none. Answer only a number or the word none.
        """

    /// Invented examples, in both languages, including two markers used as content. None is a corpus text.
    static let examples: [(text: String, answer: String)] = [
        ("[1]zarezerwuj [2]stolik [3]na [4]osiem [5]osób <<nie, czekaj>> na dziesięć osób w sobotę", "3"),
        ("[1]send [2]the [3]invoice [4]to [5]Greg <<I mean>> to Helen by friday", "4"),
        ("[1]we [2]should <<wait>> for the delivery before we sign", "none"),
        ("[1]odbierz [2]paczkę [3]w [4]poniedziałek <<przepraszam>> we wtorek rano", "3"),
        ("[1]to [2]jest <<właściwie>> dobry pomysł na jutro", "none"),
        ("[1]Ania [2]przyjdzie [3]o [4]piątej [5]po [6]pracy <<nie, to znaczy>> o szóstej po zajęciach", "3"),
    ]

    static func userMessage(_ query: Query) -> String {
        let before = query.words[..<query.marker.start].enumerated().map { "[\($0.offset + 1)]\($0.element)" }
        let marker = query.words[query.marker.start..<query.marker.end].joined(separator: " ")
        let after = query.words[query.marker.end...].joined(separator: " ")
        return before.joined(separator: " ") + " <<" + marker + ">> " + after
    }

    static func messages(for query: Query) -> [ChatMessage] {
        var messages = [ChatMessage(role: "system", content: system)]
        for example in examples {
            messages.append(ChatMessage(role: "user", content: example.text))
            messages.append(ChatMessage(role: "assistant", content: example.answer))
        }
        messages.append(ChatMessage(role: "user", content: userMessage(query)))
        return messages
    }

    /// GBNF that allows only `none` or one of the numbers of the window.
    static func grammar(for window: Range<Int>) -> String {
        let numbers = window.map { "\"\($0 + 1)\"" }
        return "root ::= " + (["\"none\""] + numbers).joined(separator: " | ")
    }

    /// An answer that is not exactly `none` or a number of the window is an invalid answer, which means `none`.
    static func parse(_ answer: String, window: Range<Int>) -> (decision: Decision, valid: Bool) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "none" { return (.none, true) }
        if let number = Int(text), window.contains(number - 1) { return (.start(number - 1), true) }
        return (.none, false)
    }

    // MARK: running a chunk

    struct Step {
        let marker: Marker
        let window: Range<Int>
        let decision: Decision
        /// The marker's words as keys, for the metrics.
        let markerKeys: [String]
    }

    struct Outcome {
        let text: String
        let steps: [Step]
        /// Markers at the very start of the chunk have no words to take back, so no model call is made.
        var calls: Int { steps.count }
    }

    /// Resolves the markers left to right. `none` skips the marker (it stays in the text); a removal continues
    /// from the start of the removed span, because the words before it are not touched.
    static func run(
        _ text: String, limit: Int, negationRule useRule: Bool,
        decide: (Query) throws -> Decision
    ) rethrows -> Outcome {
        var words = words(text)
        let polish = Language.dominant(in: text) == .polish
        var steps: [Step] = []
        var from = 0
        while let found = marker(in: words.map(key), from: from) {
            let window = window(before: found, limit: limit)
            if window.isEmpty {
                from = found.end
                continue
            }
            let query = Query(words: words, marker: found, window: window, polish: polish)
            var decision = try decide(query)
            if useRule { decision = negationRule(decision, in: query) }
            steps.append(
                Step(
                    marker: found, window: window, decision: decision,
                    markerKeys: words[found.start..<found.end].map(key)))
            switch decision {
            case .none: from = found.end
            case .start(let start):
                words = apply(words, marker: found, decision: decision)
                from = start
            }
        }
        return Outcome(text: words.joined(separator: " "), steps: steps)
    }
}

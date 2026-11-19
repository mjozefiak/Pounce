import Foundation

/// Replaces what the user said with their own spelling of a term (dictation vocabulary, DICT-1.1).
///
/// Pure and deterministic: no I/O, no model. Rules:
/// - The text is cut into tokens (runs of letters and digits). Tokens and aliases are compared in the
///   `TextNormalizer` form, so case and diacritics do not matter ("zrodlo" matches "źródło").
/// - An alias matches only whole tokens, never a part of a word ("plan" does not match "planowanie"), and
///   a multi-word alias needs the words to be separated by white space only: punctuation breaks it.
/// - The term itself counts as an alias, so a wrong capitalisation ("authservice") is fixed too.
/// - At each position the alias with the most words wins, then the one from the earlier entry; an alias
///   given by two entries belongs to the first. The scan is left to right over non-overlapping matches
///   and a replacement is never scanned again, so rules cannot chain or loop.
/// - No inflection: "AuthService" does not match "auth servisu". Add the form as an alias.
/// - Text outside the matches, punctuation included, is kept byte for byte.
public struct TermReplacer: Sendable {
    public struct Entry: Equatable, Hashable, Sendable {
        public var term: String
        public var aliases: [String]

        public init(term: String, aliases: [String] = []) {
            self.term = term
            self.aliases = aliases
        }
    }

    /// An alias longer than this many words is ignored.
    public static let maximumAliasWords = 8

    private struct Rule: Sendable {
        let tokens: [String]
        let replacement: String
    }

    /// Rules by the first token of the alias, longest alias first.
    private let rulesByFirstToken: [String: [Rule]]
    public let isEmpty: Bool

    public init(entries: [Entry]) {
        var seen = Set<[String]>()
        var grouped: [String: [Rule]] = [:]
        for entry in entries {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for alias in entry.aliases + [term] {
                let tokens = Self.tokens(of: alias).map(\.normalized)
                guard !tokens.isEmpty, tokens.count <= Self.maximumAliasWords,
                    seen.insert(tokens).inserted
                else { continue }
                grouped[tokens[0], default: []].append(Rule(tokens: tokens, replacement: term))
            }
        }
        for key in grouped.keys {
            // Stable: equal lengths keep the entry order.
            grouped[key] = grouped[key]?.enumerated()
                .sorted { ($0.element.tokens.count, $1.offset) > ($1.element.tokens.count, $0.offset) }
                .map(\.element)
        }
        rulesByFirstToken = grouped
        isEmpty = grouped.isEmpty
    }

    public func apply(to text: String) -> String {
        guard !isEmpty else { return text }
        let tokens = Self.tokens(of: text)
        guard !tokens.isEmpty else { return text }
        var output = ""
        var copied = text.startIndex
        var index = 0
        while index < tokens.count {
            guard let rules = rulesByFirstToken[tokens[index].normalized],
                let (rule, last) = Self.firstMatch(rules, tokens: tokens, at: index, text: text)
            else {
                index += 1
                continue
            }
            output += text[copied..<tokens[index].range.lowerBound]
            output += rule.replacement
            copied = tokens[last].range.upperBound
            index = last + 1
        }
        output += text[copied...]
        return output
    }

    private static func firstMatch(
        _ rules: [Rule], tokens: [Token], at start: Int, text: String
    ) -> (Rule, Int)? {
        for rule in rules where start + rule.tokens.count <= tokens.count {
            var matches = true
            for offset in 0..<rule.tokens.count {
                let token = tokens[start + offset]
                if token.normalized != rule.tokens[offset] {
                    matches = false
                    break
                }
                if offset > 0 {
                    let gap = text[tokens[start + offset - 1].range.upperBound..<token.range.lowerBound]
                    if !gap.allSatisfy(\.isWhitespace) {
                        matches = false
                        break
                    }
                }
            }
            if matches { return (rule, start + rule.tokens.count - 1) }
        }
        return nil
    }

    private struct Token {
        let range: Range<String.Index>
        let normalized: String
    }

    private static func tokens(of text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        func close(at end: String.Index) {
            if let begin = start {
                result.append(
                    Token(range: begin..<end, normalized: TextNormalizer.normalize(String(text[begin..<end]))))
                start = nil
            }
        }
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return result
    }
}

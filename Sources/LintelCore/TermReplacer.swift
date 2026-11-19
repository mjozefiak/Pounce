import Foundation

/// Replaces what the user said with their own spelling of a term (dictation vocabulary, DICT-1.1).
///
/// Pure and deterministic: no I/O, no model. Rules:
/// - The text is cut into tokens (runs of letters and digits). Tokens and aliases are compared in the
///   `TextNormalizer` form, so case and diacritics do not matter ("zrodlo" matches "źródło").
/// - An alias matches only whole tokens, never a part of a word ("plan" does not match "planowanie"), and
///   never a part of a compound: a match is refused when the character before its first token is a joiner
///   (`_ - ‐ ' ’ . @ / \`) that follows a letter or digit, or the character after its last token is a joiner
///   followed by a letter or digit. "lodz." at the end of a sentence, "(lodz)" and "lodz..." match;
///   "user@lodz.pl", "my_lodz", "pre-lodz" and "don't" (alias "don") do not.
/// - A multi-word alias keeps its gaps. A gap of white space only matches any white space in the text that
///   holds no paragraph break (two or more newlines never join an alias); any other gap matches a text gap
///   equal to it once white space is removed ("e-mail" matches "e-mail" and "e - mail", not "e mail").
/// - The term itself counts as an alias, so a wrong capitalisation ("authservice") is fixed too.
/// - At each position the alias with the most words wins, then the one from the earlier entry; an alias
///   given by two entries belongs to the first. The scan is left to right over non-overlapping matches
///   and a replacement is never scanned again, so rules cannot chain or loop.
/// - Aliases live in a token trie, so a position costs at most `maximumAliasWords` steps however many
///   aliases share a first word.
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

    private struct Key: Hashable, Sendable {
        /// "" for a white-space gap (and for the first token), else the gap without white space.
        let gap: String
        let token: String
    }

    private struct Node: Sendable {
        var children: [Key: Int] = [:]
        var replacement: String?
    }

    /// Node 0 is the root.
    private let nodes: [Node]
    public let isEmpty: Bool

    public init(entries: [Entry]) {
        var nodes = [Node()]
        var any = false
        for entry in entries {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for alias in entry.aliases + [term] {
                let tokens = Self.tokens(of: alias)
                guard !tokens.isEmpty, tokens.count <= Self.maximumAliasWords else { continue }
                var node = 0
                for (offset, token) in tokens.enumerated() {
                    let key = Key(gap: offset == 0 ? "" : token.gapKey(inAlias: true), token: token.normalized)
                    if let next = nodes[node].children[key] {
                        node = next
                    } else {
                        nodes.append(Node())
                        nodes[node].children[key] = nodes.count - 1
                        node = nodes.count - 1
                    }
                }
                // An identical alias belongs to the earlier entry.
                if nodes[node].replacement == nil {
                    nodes[node].replacement = term
                    any = true
                }
            }
        }
        self.nodes = nodes
        isEmpty = !any
    }

    public func apply(to text: String) -> String {
        guard !isEmpty else { return text }
        let tokens = Self.tokens(of: text)
        guard !tokens.isEmpty else { return text }
        var output = ""
        var copied = text.startIndex
        var index = 0
        while index < tokens.count {
            guard Self.startIsClean(tokens[index], in: text),
                let (replacement, last) = longestMatch(tokens, from: index, text: text)
            else {
                index += 1
                continue
            }
            output += text[copied..<tokens[index].range.lowerBound]
            output += replacement
            copied = tokens[last].range.upperBound
            index = last + 1
        }
        output += text[copied...]
        return output
    }

    /// The deepest node with a replacement on the path of the tokens from `start`, with the index of its
    /// last token. At most `maximumAliasWords` steps.
    private func longestMatch(_ tokens: [Token], from start: Int, text: String) -> (String, Int)? {
        var node = 0
        var best: (String, Int)?
        let limit = min(tokens.count, start + Self.maximumAliasWords)
        var position = start
        while position < limit {
            let token = tokens[position]
            let gap = position == start ? "" : token.gapKey(inAlias: false)
            guard let next = nodes[node].children[Key(gap: gap, token: token.normalized)] else { break }
            node = next
            if let replacement = nodes[node].replacement, Self.endIsClean(token, in: text) {
                best = (replacement, position)
            }
            position += 1
        }
        return best
    }

    private static let joiners: Set<Character> = ["_", "-", "\u{2010}", "'", "\u{2019}", ".", "@", "/", "\\"]

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// False when the token is glued to a word before it by a joiner ("my_lodz", "user@lodz").
    private static func startIsClean(_ token: Token, in text: String) -> Bool {
        let start = token.range.lowerBound
        guard start > text.startIndex else { return true }
        let before = text.index(before: start)
        guard joiners.contains(text[before]), before > text.startIndex else { return true }
        return !isWordCharacter(text[text.index(before: before)])
    }

    /// False when the token is glued to a word after it by a joiner ("lodz.pl", "don't").
    private static func endIsClean(_ token: Token, in text: String) -> Bool {
        let end = token.range.upperBound
        guard end < text.endIndex, joiners.contains(text[end]) else { return true }
        let after = text.index(after: end)
        guard after < text.endIndex else { return true }
        return !isWordCharacter(text[after])
    }

    private struct Token {
        let range: Range<String.Index>
        let normalized: String
        /// The text between the previous token and this one ("" for the first token).
        let gap: String

        /// "" for white space only (a paragraph break in the text gives a key nothing matches), else the
        /// gap without white space.
        func gapKey(inAlias: Bool) -> String {
            if gap.allSatisfy(\.isWhitespace) {
                if !inAlias, gap.filter(\.isNewline).count >= 2 { return "\u{0}paragraph" }
                return ""
            }
            return String(gap.filter { !$0.isWhitespace })
        }
    }

    private static func tokens(of text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        var previousEnd = text.startIndex
        var index = text.startIndex
        func close(at end: String.Index) {
            if let begin = start {
                result.append(
                    Token(
                        range: begin..<end, normalized: TextNormalizer.normalize(String(text[begin..<end])),
                        gap: String(text[previousEnd..<begin])))
                previousEnd = end
                start = nil
            }
        }
        while index < text.endIndex {
            let character = text[index]
            if isWordCharacter(character) {
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

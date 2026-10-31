import PounceKit

/// fzf v2 scoring constants (junegunn/fzf `algo.go`, MIT).
enum FuzzyScoring {
    static let match = 16
    static let gapStart = -3
    static let gapExtension = -1
    static let boundary = match / 2
    static let nonWord = match / 2
    static let camel123 = boundary + gapExtension
    static let consecutive = -(gapStart + gapExtension)
    static let firstCharMultiplier = 2
    static let boundaryWhite = boundary + 2
    static let boundaryDelimiter = boundary + 1

    /// The bonus for matching a character of class `current` that follows one of class `previous`.
    static func bonus(previous: CharacterClass, current: CharacterClass) -> Int16 {
        let value: Int
        if current.isWord {
            switch previous {
            case .whitespace: value = boundaryWhite
            case .delimiter: value = boundaryDelimiter
            case .nonWord: value = boundary
            case .lower where current == .upper: value = camel123
            case .lower, .upper, .letter: value = current == .number ? camel123 : 0
            case .number: value = 0
            }
        } else {
            value = current == .whitespace ? boundaryWhite : nonWord
        }
        return Int16(value)
    }

    /// The best score a query of `length` characters could reach, used to scale fuzzy scores to 0…1.
    static func maximum(forQueryLength length: Int) -> Int {
        length * (match + boundaryWhite) + boundaryWhite * (firstCharMultiplier - 1)
    }
}

/// Matches a normalised query against a prepared title and decides the tier:
/// exact > prefix > word start or acronym ("vsc" → Visual Studio Code) > substring > fuzzy.
///
/// The score is in 0…1 and only orders candidates within a tier. Highlight ranges are `Character`
/// offsets in the original title.
public enum FuzzyMatcher {
    /// Returns `nil` when the query does not match at all or is empty.
    public static func match(_ query: NormalizedQuery, in text: NormalizedText) -> MatchResult? {
        match(Array(query.normalized.unicodeScalars), in: text)
    }

    /// Same as `match(_:in:)` for a query already split into scalars (sources do this once per query).
    public static func match(_ query: [Unicode.Scalar], in text: NormalizedText) -> MatchResult? {
        let target = text.scalars
        guard !query.isEmpty, query.count <= target.count else { return nil }
        let length = Double(target.count)
        let coverage = Double(query.count) / length

        if target == query {
            return result(.exact, 1, Array(0..<target.count), text)
        }
        if target.starts(with: query) {
            return result(.prefix, coverage, Array(0..<query.count), text)
        }

        if let wordStart = wordStartMatch(query, text) {
            return wordStart
        }

        if let position = firstIndex(of: query, in: target) {
            let score = coverage * (1 - 0.5 * Double(position) / length)
            return result(.substring, score, Array(position..<position + query.count), text)
        }

        guard let (score, positions) = fuzzy(query, text) else { return nil }
        let scaled = Double(score) / Double(FuzzyScoring.maximum(forQueryLength: query.count))
        return result(.fuzzy, min(max(scaled, 0), 1), positions, text)
    }

    // MARK: Tiers

    /// A substring that starts at a word boundary, or the query as a subsequence of word initials.
    private static func wordStartMatch(_ query: [Unicode.Scalar], _ text: NormalizedText) -> MatchResult? {
        let target = text.scalars
        let length = Double(target.count)
        var best: MatchResult?

        var index = 1
        while index + query.count <= target.count {
            if isWordStart(index, text), target[index..<index + query.count].elementsEqual(query) {
                let score = 0.9 * Double(query.count) / length * (1 - 0.25 * Double(index) / length)
                best = result(.wordStart, score, Array(index..<index + query.count), text)
                break
            }
            index += 1
        }

        if query.count >= 2 {
            let initials = (0..<target.count).filter { isWordStart($0, text) }
            var positions: [Int] = []
            var next = 0
            for position in initials where next < query.count && target[position] == query[next] {
                positions.append(position)
                next += 1
            }
            if next == query.count {
                let score = 0.8 * Double(query.count) / Double(initials.count)
                if score > (best?.score ?? -1) {
                    best = result(.wordStart, score, positions, text)
                }
            }
        }
        return best
    }

    private static func isWordStart(_ index: Int, _ text: NormalizedText) -> Bool {
        guard index == 0 || text.bonuses[index] >= Int16(FuzzyScoring.camel123) else { return false }
        return CharacterClass(text.scalars[index]).isWord
    }

    private static func firstIndex(of query: [Unicode.Scalar], in target: [Unicode.Scalar]) -> Int? {
        guard let first = query.first else { return nil }
        var index = 0
        while index + query.count <= target.count {
            if target[index] == first, target[index..<index + query.count].elementsEqual(query) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// fzf v2: the best-scoring alignment of the query as a subsequence, with boundary, camel-case and
    /// consecutive bonuses and gap penalties. O(query × text) time and memory.
    static func fuzzy(_ query: [Unicode.Scalar], _ text: NormalizedText) -> (Int, [Int])? {
        let target = text.scalars
        let rows = query.count
        let columns = target.count

        // Cheap rejection: the query must be a subsequence.
        var next = 0
        for scalar in target where next < rows && scalar == query[next] {
            next += 1
        }
        guard next == rows else { return nil }

        let invalid = Int.min / 2
        var score = [Int](repeating: invalid, count: rows * columns)
        var run = [Int](repeating: 0, count: rows * columns)
        var previous = [Int](repeating: -1, count: rows * columns)

        for column in 0..<columns where target[column] == query[0] {
            score[column] = FuzzyScoring.match + Int(text.bonuses[column]) * FuzzyScoring.firstCharMultiplier
            run[column] = 1
        }

        for row in 1..<rows {
            let above = (row - 1) * columns
            let here = row * columns
            var gapBest = invalid
            var gapFrom = -1
            for column in row..<columns {
                if column >= 2, score[above + column - 2] > invalid {
                    let opened = score[above + column - 2] + FuzzyScoring.gapStart
                    let extended = gapBest > invalid ? gapBest + FuzzyScoring.gapExtension : invalid
                    if opened >= extended {
                        gapBest = opened
                        gapFrom = column - 2
                    } else {
                        gapBest = extended
                    }
                } else if gapBest > invalid {
                    gapBest += FuzzyScoring.gapExtension
                }
                guard target[column] == query[row] else { continue }
                let bonus = Int(text.bonuses[column])

                var best = invalid
                var from = -1
                var length = 1
                let diagonal = score[above + column - 1]
                if diagonal > invalid {
                    let chain = run[above + column - 1] + 1
                    let chainStart = Int(text.bonuses[column - chain + 1])
                    let chained = diagonal + FuzzyScoring.match + max(bonus, FuzzyScoring.consecutive, chainStart)
                    best = chained
                    from = column - 1
                    length = chain
                }
                if gapBest > invalid {
                    let gapped = gapBest + FuzzyScoring.match + bonus
                    if gapped > best {
                        best = gapped
                        from = gapFrom
                        length = 1
                    }
                }
                guard best > invalid else { continue }
                score[here + column] = best
                run[here + column] = length
                previous[here + column] = from
            }
        }

        let last = (rows - 1) * columns
        var bestColumn = -1
        var bestScore = invalid
        for column in 0..<columns where score[last + column] > bestScore {
            bestScore = score[last + column]
            bestColumn = column
        }
        guard bestColumn >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: rows)
        var column = bestColumn
        var row = rows - 1
        while row >= 0, column >= 0 {
            positions[row] = column
            column = previous[row * columns + column]
            row -= 1
        }
        return (bestScore, positions)
    }

    // MARK: Results

    private static func result(_ tier: MatchTier, _ score: Double, _ positions: [Int], _ text: NormalizedText)
        -> MatchResult
    {
        MatchResult(tier: tier, score: score, highlightRanges: highlightRanges(positions, text))
    }

    /// Maps matched normalised positions to merged `Character` ranges of the original title.
    static func highlightRanges(_ positions: [Int], _ text: NormalizedText) -> [Range<Int>] {
        var offsets = positions.compactMap { $0 < text.originalOffsets.count ? text.originalOffsets[$0] : nil }
        offsets = Array(Set(offsets)).sorted()
        var ranges: [Range<Int>] = []
        for offset in offsets {
            if let last = ranges.last, last.upperBound == offset {
                ranges[ranges.count - 1] = last.lowerBound..<offset + 1
            } else {
                ranges.append(offset..<offset + 1)
            }
        }
        return ranges
    }
}

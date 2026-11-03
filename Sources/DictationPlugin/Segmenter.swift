import Foundation

/// Builds the chunks that go to the formatting model from the transcribed speech segments (spec:
/// `Segmenter`). Pure logic.
///
/// A chunk ends at a pause of 1.5 s or more once it holds about 40 words, and never holds more than 60
/// words (ADR 0004): longer text is cut at the end of a sentence, or at the 60th word when it has none.
struct Segmenter: Sendable {
    struct Chunk: Equatable, Sendable {
        let text: String
        /// The chunk ended at a pause, so a paragraph break follows; a forced cut continues the paragraph.
        let endsParagraph: Bool
    }

    var softWords = 40
    var pause: Double = 1.5
    var maxWords = 60

    private var words: [Substring] = []

    init(softWords: Int = 40, pause: Double = 1.5, maxWords: Int = 60) {
        self.softWords = softWords
        self.pause = pause
        self.maxWords = maxWords
    }

    /// Adds the next segment; returns the chunks that are complete now.
    /// - Parameter pauseBefore: seconds of silence between the previous segment and this one.
    mutating func add(_ text: String, pauseBefore: Double) -> [Chunk] {
        var done: [Chunk] = []
        if words.count >= softWords, pauseBefore >= pause {
            done.append(Chunk(text: join(words), endsParagraph: true))
            words = []
        }
        words.append(contentsOf: text.split(whereSeparator: \.isWhitespace))
        while words.count > maxWords {
            let cut = cutIndex()
            done.append(Chunk(text: join(words[..<cut]), endsParagraph: false))
            words.removeFirst(cut)
        }
        return done
    }

    /// The end of the recording: what is left, cut to the same limit.
    mutating func flush() -> [Chunk] {
        var done: [Chunk] = []
        while words.count > maxWords {
            let cut = cutIndex()
            done.append(Chunk(text: join(words[..<cut]), endsParagraph: false))
            words.removeFirst(cut)
        }
        if !words.isEmpty {
            done.append(Chunk(text: join(words), endsParagraph: true))
            words = []
        }
        return done
    }

    /// How many words go into the next chunk: up to the last sentence end within the limit, else the limit.
    private func cutIndex() -> Int {
        let limit = min(maxWords, words.count)
        for index in stride(from: limit, through: 1, by: -1) {
            if let last = words[index - 1].last, ".?!…".contains(last) { return index }
        }
        return limit
    }

    private func join<S: Sequence>(_ parts: S) -> String where S.Element == Substring {
        parts.joined(separator: " ")
    }
}

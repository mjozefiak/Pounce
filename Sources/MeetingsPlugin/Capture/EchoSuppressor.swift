import Foundation
import LintelCore

/// One transcribed segment of one track, on the shared timeline (milliseconds since the common start).
struct TrackSegment: Equatable, Sendable {
    enum Track: Equatable, Sendable {
        case microphone
        case system
    }

    let track: Track
    let startMs: Int64
    let endMs: Int64
    let text: String
}

/// Drops the microphone's copy of what the speakers played (spec "Echo"): a microphone segment that overlaps
/// in time a system segment and reads like it is an echo, and the system track wins. Pure logic.
struct EchoSuppressor: Sendable {
    /// Similarity (0...1) at or above which two overlapping texts are the same speech.
    var similarityThreshold: Double = 0.8
    /// Part of the shorter segment that must overlap in time. The speaker-to-microphone delay and the
    /// separate voice activity boundaries of the tracks never line up exactly.
    var minimumOverlapFraction: Double = 0.3
    /// Part of the MICROPHONE segment that the system segments must cover in time: a short mic remark that
    /// merely touches a long system segment is not its echo.
    var minimumMicOverlapShare: Double = 0.5
    /// A microphone segment shorter than both limits is never treated as an echo: "tak" or "thank you" said
    /// by the user while the other side says the same would be lost, and a short text is too weak a match.
    var minimumWords = 4
    var minimumCharacters = 15

    /// `segments` without the microphone echoes, in the original order. System segments are never removed.
    func suppressing(_ segments: [TrackSegment]) -> [TrackSegment] {
        let system = segments.filter { $0.track == .system }
        return segments.filter { segment in
            segment.track == .system || !isEcho(segment, of: system)
        }
    }

    func isEcho(_ mic: TrackSegment, of system: [TrackSegment]) -> Bool {
        let micText = Self.normalize(mic.text)
        guard isLongEnough(micText) else { return false }
        let overlapping = system.filter { overlaps(mic, $0) }.sorted { $0.startMs < $1.startMs }
        guard !overlapping.isEmpty, micShare(mic, covered: overlapping) >= minimumMicOverlapShare else {
            return false
        }
        // Against each overlapping segment and against their concatenation, because the two tracks cut
        // the same speech at different places.
        var candidates = overlapping.map { Self.normalize($0.text) }
        if overlapping.count > 1 { candidates.append(candidates.joined(separator: " ")) }
        return candidates.contains { Self.similarity(micText, $0) >= similarityThreshold }
    }

    private func isLongEnough(_ normalized: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        return normalized.split(separator: " ").count >= minimumWords || normalized.count >= minimumCharacters
    }

    /// The part of `mic` (0...1) that the system segments cover in time.
    private func micShare(_ mic: TrackSegment, covered system: [TrackSegment]) -> Double {
        let duration = max(1, mic.endMs - mic.startMs)
        let covered = system.reduce(Int64(0)) {
            $0 + max(0, min(mic.endMs, $1.endMs) - max(mic.startMs, $1.startMs))
        }
        return Double(min(covered, duration)) / Double(duration)
    }

    private func overlaps(_ first: TrackSegment, _ second: TrackSegment) -> Bool {
        let overlap = min(first.endMs, second.endMs) - max(first.startMs, second.startMs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(first.endMs - first.startMs, second.endMs - second.startMs))
        return Double(overlap) / Double(shorter) >= minimumOverlapFraction
    }

    // MARK: Text similarity

    /// Lowercase, diacritics folded, punctuation turned into single spaces.
    static func normalize(_ text: String) -> String {
        let folded = TextNormalizer.normalize(text)
        let cleaned = folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// The larger of the character edit-distance ratio and the word-sequence similarity (Dice over the longest
    /// common subsequence of words), both on normalised text. Both respect word order, so the same words in
    /// another order are not a match.
    static func similarity(_ first: String, _ second: String) -> Double {
        if first.isEmpty || second.isEmpty { return 0 }
        if first == second { return 1 }
        return max(editRatio(first, second), wordSequenceDice(first, second))
    }

    private static func editRatio(_ first: String, _ second: String) -> Double {
        let a = Array(first.unicodeScalars)
        let b = Array(second.unicodeScalars)
        let longest = max(a.count, b.count)
        guard !a.isEmpty, !b.isEmpty else { return a.count == b.count ? 1 : 0 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[b.count]) / Double(longest)
    }

    private static func wordSequenceDice(_ first: String, _ second: String) -> Double {
        let a = first.split(separator: " ")
        let b = second.split(separator: " ")
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return 2 * Double(previous[b.count]) / Double(a.count + b.count)
    }
}

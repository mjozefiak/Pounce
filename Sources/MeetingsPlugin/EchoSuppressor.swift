import Foundation
import PounceCore

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

    /// `segments` without the microphone echoes, in the original order. System segments are never removed.
    func suppressing(_ segments: [TrackSegment]) -> [TrackSegment] {
        let system = segments.filter { $0.track == .system }
        return segments.filter { segment in
            segment.track == .system || !isEcho(segment, of: system)
        }
    }

    func isEcho(_ mic: TrackSegment, of system: [TrackSegment]) -> Bool {
        let overlapping = system.filter { overlaps(mic, $0) }.sorted { $0.startMs < $1.startMs }
        guard !overlapping.isEmpty else { return false }
        let micText = Self.normalize(mic.text)
        guard !micText.isEmpty else { return false }
        // Against each overlapping segment and against their concatenation, because the two tracks cut
        // the same speech at different places.
        var candidates = overlapping.map { Self.normalize($0.text) }
        if overlapping.count > 1 { candidates.append(candidates.joined(separator: " ")) }
        return candidates.contains { Self.similarity(micText, $0) >= similarityThreshold }
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

    /// The larger of the edit-distance ratio and the word overlap (Dice), both on normalised text.
    static func similarity(_ first: String, _ second: String) -> Double {
        if first.isEmpty || second.isEmpty { return 0 }
        if first == second { return 1 }
        return max(editRatio(first, second), wordDice(first, second))
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

    private static func wordDice(_ first: String, _ second: String) -> Double {
        var counts: [Substring: Int] = [:]
        let a = first.split(separator: " ")
        let b = second.split(separator: " ")
        for word in a { counts[word, default: 0] += 1 }
        var shared = 0
        for word in b where counts[word, default: 0] > 0 {
            counts[word, default: 0] -= 1
            shared += 1
        }
        return 2 * Double(shared) / Double(a.count + b.count)
    }
}

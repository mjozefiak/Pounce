import Foundation

/// A transcript segment as the assigner sees it: where it is and on which track it was heard.
struct SegmentRef: Equatable, Sendable {
    let id: Int64
    let channel: AudioChannel
    let startMs: Int
    let endMs: Int

    var durationMs: Int { max(0, endMs - startMs) }
}

/// What to write for a meeting: its speakers and which speaker each segment belongs to.
struct SpeakerPlan: Equatable, Sendable {
    struct Speaker: Equatable, Sendable {
        var label: String
        var isSelf: Bool
        var channel: AudioChannel
    }

    var mode: SpeakerMode
    var speakers: [Speaker] = []
    /// Segment id to an index into `speakers`. A segment missing here keeps `speaker_id` NULL.
    var assignments: [Int64: Int] = [:]
}

/// The labels stored in `meeting_speaker.label` (spec: Data Model; Polish data, as the spec has them).
enum SpeakerLabels {
    static let me = "Ja"
    static let others = "Inni"
    static let numberedPrefix = "Mówca "

    static func numbered(_ number: Int) -> String { numberedPrefix + String(number) }
}

/// Turns the diarizer's clusters into the meeting's speakers (pure, no I/O; spec: Architecture).
///
/// - The two tracks were diarized separately, so their clusters are different speakers: the lists are joined,
///   not matched. A cluster that no segment falls into creates no speaker.
/// - A segment gets the speaker with the largest total time overlap on its own track. A tie goes to the
///   cluster that starts earlier, then to the lower cluster id; a segment with no overlap at all gets the
///   nearest span's speaker.
/// - "Ja" (`is_self`) goes to the dominant microphone speaker (most segment time) **only when the system track
///   has speech**: that is an online meeting, and the microphone is the user. In a meeting held in a room the
///   system track is silent, the microphone hears everybody, and every speaker is "Mówca N" until the user
///   marks one ("To ja").
/// - The speakers are numbered "Mówca 1…" in order of first appearance across both tracks (Ja not counted).
enum SpeakerAssigner {
    static func diarized(segments: [SegmentRef], spans: [AudioChannel: [DiarizedSpan]]) -> SpeakerPlan {
        guard !segments.isEmpty else { return SpeakerPlan(mode: .diarized) }
        var picks: [Int64: Cluster] = [:]
        for segment in segments {
            picks[segment.id] = cluster(for: segment, in: spans[segment.channel] ?? [])
        }
        var stats: [Cluster: (duration: Int, first: Int)] = [:]
        for segment in segments {
            guard let pick = picks[segment.id] else { continue }
            let old = stats[pick]
            stats[pick] = ((old?.duration ?? 0) + segment.durationMs, min(old?.first ?? .max, segment.startMs))
        }
        let ordered = stats.keys.sorted { lhs, rhs in
            let (a, b) = (stats[lhs]?.first ?? 0, stats[rhs]?.first ?? 0)
            if a != b { return a < b }
            if lhs.channel != rhs.channel { return lhs.channel == .mic }
            return precedes(lhs.id, rhs.id)
        }

        let systemHasSpeech =
            segments.contains { $0.channel == .system } || !(spans[.system] ?? []).isEmpty
        var selfCluster: Cluster?
        if systemHasSpeech {
            selfCluster =
                ordered.filter { $0.channel == .mic }.max { lhs, rhs in
                    let (a, b) = (stats[lhs]?.duration ?? 0, stats[rhs]?.duration ?? 0)
                    if a != b { return a < b }
                    // On a tie the earlier speaker wins; `ordered` is by first appearance.
                    return (ordered.firstIndex(of: lhs) ?? 0) > (ordered.firstIndex(of: rhs) ?? 0)
                }
        }

        var plan = SpeakerPlan(mode: .diarized)
        var indexOf: [Cluster: Int] = [:]
        var number = 0
        for cluster in ordered {
            let isSelf = cluster == selfCluster
            if !isSelf { number += 1 }
            indexOf[cluster] = plan.speakers.count
            plan.speakers.append(
                .init(
                    label: isSelf ? SpeakerLabels.me : SpeakerLabels.numbered(number), isSelf: isSelf,
                    channel: cluster.channel))
        }
        for (id, pick) in picks { plan.assignments[id] = indexOf[pick] }
        return plan
    }

    /// The fallback (diarization failed, was skipped or was over budget): the mode is always `channels`, so the
    /// meeting window shows its banner, and the labels follow the tracks.
    /// - Both tracks have speech: the microphone is "Ja" and the system track "Inni".
    /// - Only the microphone has speech: it may be the whole room (a meeting held live), so no claim of self is
    ///   made and the track gets one neutral "Mówca 1".
    /// - Only the system track has speech: "Inni" (it is by definition what the others said).
    /// `none` is reserved for the setting `diarization` being off (`none()`). Spec discrepancy resolved in
    /// ADR 0007: the spec says `channels` for every fallback.
    static func channels(segments: [SegmentRef]) -> SpeakerPlan {
        let hasMic = segments.contains { $0.channel == .mic }
        let hasSystem = segments.contains { $0.channel == .system }
        var plan = SpeakerPlan(mode: .channels)
        switch (hasMic, hasSystem) {
        case (true, true):
            plan.speakers = [
                .init(label: SpeakerLabels.me, isSelf: true, channel: .mic),
                .init(label: SpeakerLabels.others, isSelf: false, channel: .system),
            ]
            for segment in segments { plan.assignments[segment.id] = segment.channel == .mic ? 0 : 1 }
        case (true, false):
            plan.speakers = [.init(label: SpeakerLabels.numbered(1), isSelf: false, channel: .mic)]
            for segment in segments { plan.assignments[segment.id] = 0 }
        case (false, true):
            plan.speakers = [.init(label: SpeakerLabels.others, isSelf: false, channel: .system)]
            for segment in segments { plan.assignments[segment.id] = 0 }
        case (false, false):
            break
        }
        return plan
    }

    /// No labels: the track stays in `meeting_segment.channel` as a hint.
    static func none() -> SpeakerPlan { SpeakerPlan(mode: .none) }

    // MARK: Assignment

    private struct Cluster: Hashable {
        let channel: AudioChannel
        /// Empty for a track that has speech but no spans at all (one speaker for the whole track).
        let id: String
    }

    private static func cluster(for segment: SegmentRef, in spans: [DiarizedSpan]) -> Cluster? {
        guard !spans.isEmpty else { return Cluster(channel: segment.channel, id: "") }
        var overlap: [String: (total: Int, first: Int)] = [:]
        for span in spans {
            let shared = min(segment.endMs, span.endMs) - max(segment.startMs, span.startMs)
            guard shared > 0 else { continue }
            let old = overlap[span.cluster]
            overlap[span.cluster] = ((old?.total ?? 0) + shared, min(old?.first ?? .max, span.startMs))
        }
        if let best = overlap.min(by: { lhs, rhs in
            if lhs.value.total != rhs.value.total { return lhs.value.total > rhs.value.total }
            if lhs.value.first != rhs.value.first { return lhs.value.first < rhs.value.first }
            return precedes(lhs.key, rhs.key)
        }) {
            return Cluster(channel: segment.channel, id: best.key)
        }
        // No overlap: the nearest span (ties: the earlier one, then the lower id).
        let nearest = spans.min { lhs, rhs in
            let (a, b) = (gap(segment, lhs), gap(segment, rhs))
            if a != b { return a < b }
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            return precedes(lhs.cluster, rhs.cluster)
        }
        return nearest.map { Cluster(channel: segment.channel, id: $0.cluster) }
    }

    /// Cluster ids compare numerically where they hold numbers, so "S2" comes before "S10".
    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedAscending
    }

    private static func gap(_ segment: SegmentRef, _ span: DiarizedSpan) -> Int {
        max(0, max(segment.startMs - span.endMs, span.startMs - segment.endMs))
    }
}

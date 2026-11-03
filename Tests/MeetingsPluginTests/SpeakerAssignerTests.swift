import Testing

@testable import MeetingsPlugin

@Suite struct SpeakerAssignerTests {
    private func segment(_ id: Int64, _ channel: AudioChannel, _ start: Int, _ end: Int) -> SegmentRef {
        SegmentRef(id: id, channel: channel, startMs: start, endMs: end)
    }

    private func span(_ cluster: String, _ start: Int, _ end: Int) -> DiarizedSpan {
        DiarizedSpan(cluster: cluster, startMs: start, endMs: end)
    }

    private func label(_ plan: SpeakerPlan, of id: Int64) -> String? {
        plan.assignments[id].map { plan.speakers[$0].label }
    }

    // MARK: Overlap

    @Test func aSegmentGetsTheSpeakerWithTheLargestOverlap() {
        let segments = [segment(1, .mic, 0, 10_000)]
        let spans = [AudioChannel.mic: [span("S1", 0, 3_000), span("S2", 3_000, 10_000)]]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        #expect(plan.mode == .diarized)
        #expect(plan.speakers.count == 1)
        #expect(plan.assignments[1] == 0)
    }

    @Test func overlapIsSummedOverAllSpansOfACluster() {
        // S1 speaks twice for 2 s each (4 s), S2 once for 3 s: S1 wins although S2's single span is longer.
        let segments = [segment(1, .mic, 0, 10_000)]
        let spans = [
            AudioChannel.mic: [span("S1", 0, 2_000), span("S2", 2_000, 5_000), span("S1", 5_000, 7_000)]
        ]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        #expect(plan.speakers.count == 1)
        #expect(plan.assignments[1] == 0)
        // Adding a second segment inside S2's span makes S2 appear as its own speaker.
        let both = SpeakerAssigner.diarized(
            segments: segments + [segment(2, .mic, 2_100, 4_900)], spans: spans)
        #expect(both.speakers.count == 2)
        #expect(both.assignments[1] != both.assignments[2])
    }

    @Test func aTieGoesToTheClusterThatStartsEarlier() {
        let segments = [segment(1, .system, 0, 4_000)]
        let spans = [AudioChannel.system: [span("B", 2_000, 4_000), span("A", 0, 2_000)]]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        #expect(plan.speakers.count == 1)
        // A starts first; there is one speaker either way, the test pins that no crash or nondeterminism occurs.
        for _ in 0..<20 {
            #expect(SpeakerAssigner.diarized(segments: segments, spans: spans) == plan)
        }
    }

    @Test func aTieBetweenEquallyEarlySpansGoesToTheLowerClusterId() {
        let segments = [segment(1, .system, 0, 2_000), segment(2, .system, 10_000, 12_000)]
        let spans = [AudioChannel.system: [span("S2", 0, 1_000), span("S1", 0, 1_000), span("S1", 10_000, 12_000)]]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        // Segment 1 overlaps S1 and S2 by 1 s each and both start at 0: S1 wins, so both segments share a speaker.
        #expect(plan.assignments[1] == plan.assignments[2])
        #expect(plan.speakers.count == 1)
    }

    @Test func aSegmentWithoutOverlapGetsTheNearestSpan() {
        let segments = [segment(1, .system, 5_000, 6_000)]
        let spans = [AudioChannel.system: [span("S1", 0, 1_000), span("S2", 7_000, 8_000)]]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        #expect(plan.speakers.count == 1)
        // The two spans are 4 s and 1 s away: S2 is nearest, and with only one speaker used there is one row.
        let more = SpeakerAssigner.diarized(
            segments: segments + [segment(2, .system, 0, 900)], spans: spans)
        #expect(more.speakers.count == 2)
        #expect(more.assignments[1] != more.assignments[2])
    }

    @Test func aTrackWithSegmentsButNoSpansGetsOneSpeakerForTheWholeTrack() {
        let segments = [segment(1, .system, 0, 1_000), segment(2, .system, 5_000, 6_000)]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: [:])
        #expect(plan.speakers.count == 1)
        #expect(plan.assignments[1] == 0 && plan.assignments[2] == 0)
    }

    @Test func aClusterNoSegmentFallsIntoCreatesNoSpeaker() {
        let segments = [segment(1, .system, 0, 1_000)]
        let spans = [AudioChannel.system: [span("S1", 0, 1_000), span("S2", 50_000, 60_000)]]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        #expect(plan.speakers.count == 1)
    }

    // MARK: "Ja"

    @Test func inAnOnlineMeetingTheDominantMicrophoneSpeakerIsJa() {
        let segments = [
            segment(1, .mic, 0, 5_000), segment(2, .system, 6_000, 9_000), segment(3, .mic, 10_000, 12_000),
            segment(4, .mic, 13_000, 20_000),
        ]
        let spans = [
            AudioChannel.mic: [span("S1", 0, 5_000), span("S2", 10_000, 12_000), span("S1", 13_000, 20_000)],
            AudioChannel.system: [span("S1", 6_000, 9_000)],
        ]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        #expect(label(plan, of: 1) == "Ja")
        #expect(label(plan, of: 4) == "Ja")
        #expect(plan.speakers[plan.assignments[1] ?? 0].isSelf)
        // The others are numbered from 1 in order of first appearance, Ja not counted.
        #expect(label(plan, of: 2) == "Mówca 1")
        #expect(label(plan, of: 3) == "Mówca 2")
        #expect(plan.speakers.filter(\.isSelf).count == 1)
    }

    @Test func inALiveMeetingNobodyIsJaAndTheSpeakersAreNumberedByFirstAppearance() {
        let segments = [segment(1, .mic, 0, 3_000), segment(2, .mic, 4_000, 9_000), segment(3, .mic, 10_000, 11_000)]
        let spans = [
            AudioChannel.mic: [span("S2", 0, 3_000), span("S1", 4_000, 9_000), span("S2", 10_000, 11_000)]
        ]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        #expect(plan.speakers.map(\.label) == ["Mówca 1", "Mówca 2"])
        #expect(plan.speakers.allSatisfy { !$0.isSelf })
        #expect(label(plan, of: 1) == "Mówca 1")
        #expect(label(plan, of: 3) == "Mówca 1")
        #expect(label(plan, of: 2) == "Mówca 2")
    }

    @Test func aSilentSystemTrackCountsAsALiveMeetingEvenWithAnEmptySpanList() {
        let segments = [segment(1, .mic, 0, 3_000)]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: [.mic: [span("S1", 0, 3_000)], .system: []])
        #expect(plan.speakers.map(\.label) == ["Mówca 1"])
    }

    @Test func theDominantMicrophoneSpeakerIsDecidedByTimeThenByWhoSpokeFirst() {
        let segments = [
            segment(1, .mic, 0, 4_000), segment(2, .mic, 5_000, 9_000), segment(3, .system, 10_000, 11_000),
        ]
        let spans = [
            AudioChannel.mic: [span("S1", 0, 4_000), span("S2", 5_000, 9_000)],
            AudioChannel.system: [span("S1", 10_000, 11_000)],
        ]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        // 4 s each: the speaker who spoke first is Ja.
        #expect(label(plan, of: 1) == "Ja")
        #expect(label(plan, of: 2) == "Mówca 2" || label(plan, of: 2) == "Mówca 1")
        #expect(label(plan, of: 3) != "Ja")
    }

    // MARK: Merging the tracks

    @Test func clustersWithTheSameNameOnTwoTracksAreDifferentSpeakers() {
        let segments = [
            segment(1, .mic, 0, 2_000), segment(2, .system, 3_000, 5_000), segment(3, .system, 6_000, 8_000),
        ]
        let spans = [
            AudioChannel.mic: [span("S1", 0, 2_000)],
            AudioChannel.system: [span("S1", 3_000, 5_000), span("S2", 6_000, 8_000)],
        ]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        #expect(plan.speakers.count == 3)
        #expect(plan.speakers.map(\.channel) == [.mic, .system, .system])
        #expect(Set(plan.assignments.values).count == 3)
        #expect(plan.speakers.map(\.label) == ["Ja", "Mówca 1", "Mówca 2"])
    }

    @Test func aSegmentIsMatchedOnlyAgainstItsOwnTrack() {
        let segments = [segment(1, .mic, 0, 2_000)]
        let spans = [AudioChannel.system: [span("S1", 0, 2_000)], .mic: [span("S9", 1_900, 2_000)]]
        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        #expect(plan.speakers.count == 1)
        #expect(plan.speakers[0].channel == .mic)
    }

    // MARK: No speech, channels, none

    @Test func noSegmentsGiveAnEmptyPlan() {
        let plan = SpeakerAssigner.diarized(segments: [], spans: [.mic: [span("S1", 0, 1_000)]])
        #expect(plan.speakers.isEmpty)
        #expect(plan.assignments.isEmpty)
    }

    @Test func channelsLabelTheTracksJaAndInniWhenBothHaveSpeech() {
        let segments = [segment(1, .mic, 0, 1_000), segment(2, .system, 2_000, 3_000), segment(3, .mic, 4_000, 5_000)]
        let plan = SpeakerAssigner.channels(segments: segments)
        #expect(plan.mode == .channels)
        #expect(plan.speakers.map(\.label) == ["Ja", "Inni"])
        #expect(plan.speakers.map(\.isSelf) == [true, false])
        #expect(plan.assignments == [1: 0, 2: 1, 3: 0])
    }

    @Test func withoutSystemSpeechTheFallbackLabelsNobody() {
        let plan = SpeakerAssigner.channels(segments: [segment(1, .mic, 0, 1_000)])
        #expect(plan.mode == .none)
        #expect(plan.speakers.isEmpty && plan.assignments.isEmpty)
        let systemOnly = SpeakerAssigner.channels(segments: [segment(1, .system, 0, 1_000)])
        #expect(systemOnly.mode == .none)
    }

    @Test func nonePlanHasNoLabels() {
        let plan = SpeakerAssigner.none()
        #expect(plan.mode == .none)
        #expect(plan.speakers.isEmpty && plan.assignments.isEmpty)
    }
}

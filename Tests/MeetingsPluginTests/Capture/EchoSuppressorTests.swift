import Testing

@testable import MeetingsPlugin

@Suite struct EchoSuppressorTests {
    private func mic(_ text: String, _ start: Int64, _ end: Int64) -> TrackSegment {
        TrackSegment(track: .microphone, startMs: start, endMs: end, text: text)
    }

    private func system(_ text: String, _ start: Int64, _ end: Int64) -> TrackSegment {
        TrackSegment(track: .system, startMs: start, endMs: end, text: text)
    }

    private let suppressor = EchoSuppressor()

    @Test func anEnglishEchoIsDropped() {
        let result = suppressor.suppressing([
            system("Let's review the roadmap for next quarter.", 1_000, 4_000),
            mic("Let's review the roadmap for next quarter", 1_150, 4_100),
        ])
        #expect(result.map(\.track) == [.system])
    }

    @Test func aPolishEchoIsDroppedDespiteDiacriticsAndPunctuation() {
        let result = suppressor.suppressing([
            system("Dzień dobry, zaczynamy spotkanie o budżecie.", 0, 3_000),
            mic("dzien dobry zaczynamy spotkanie o budzecie", 100, 3_100),
        ])
        #expect(result.count == 1)
        #expect(result.first?.track == .system)
    }

    @Test func aMixedLanguageEchoIsDropped() {
        let result = suppressor.suppressing([
            system("Musimy zrobić deployment na production dzisiaj", 5_000, 8_000),
            mic("Musimy zrobić deploymant na production dzisiaj", 5_080, 8_050),
        ])
        #expect(result.map(\.track) == [.system])
    }

    @Test func aNearDuplicateWithOneMisheardWordIsDropped() {
        let result = suppressor.suppressing([
            system("we should ship the release on thursday afternoon", 0, 3_000),
            mic("we should ship the release on thursday after noon", 0, 3_000),
        ])
        #expect(result.map(\.track) == [.system])
    }

    @Test func theSameTextAtAnotherTimeIsKept() {
        let segments = [
            system("Tak, zgadzam się z tym.", 1_000, 3_000),
            mic("Tak, zgadzam się z tym.", 10_000, 12_000),
        ]
        #expect(suppressor.suppressing(segments) == segments)
    }

    @Test func aSegmentThatOnlyTouchesInTimeIsKept() {
        let segments = [
            system("see you tomorrow morning", 1_000, 3_000),
            mic("see you tomorrow morning", 3_000, 5_000),
        ]
        #expect(suppressor.suppressing(segments) == segments)
    }

    @Test func aPartialOverlapStillCountsAsAnEcho() {
        let result = suppressor.suppressing([
            system("the quarterly numbers look better than expected", 1_000, 5_000),
            mic("the quarterly numbers look better than expected", 3_000, 6_500),
        ])
        #expect(result.map(\.track) == [.system])
    }

    @Test func aTinyOverlapIsNotEnough() {
        let segments = [
            system("the quarterly numbers look better than expected", 1_000, 5_000),
            mic("the quarterly numbers look better than expected", 4_900, 8_000),
        ]
        #expect(suppressor.suppressing(segments) == segments)
    }

    @Test func differentTextOnTheSameTimeIsKept() {
        let segments = [
            system("Can you share the slides with everyone?", 1_000, 4_000),
            mic("Sure, I will send them right after the call.", 1_500, 4_500),
        ]
        #expect(suppressor.suppressing(segments) == segments)
    }

    @Test func theSystemTrackIsNeverDroppedAndOrderIsKept() {
        let segments = [
            mic("hello there everyone welcome to the call", 0, 1_000),
            system("hello there everyone welcome to the call", 0, 1_000),
            system("second line", 2_000, 3_000),
            mic("my own words entirely", 4_000, 5_000),
        ]
        let result = suppressor.suppressing(segments)
        #expect(result == [segments[1], segments[2], segments[3]])
    }

    @Test func oneMicSegmentSpanningTwoSystemSegmentsIsAnEcho() {
        let result = suppressor.suppressing([
            system("first we cover the budget", 0, 2_000),
            system("then the hiring plan", 2_100, 4_000),
            mic("first we cover the budget then the hiring plan", 50, 4_050),
        ])
        #expect(result.map(\.track) == [.system, .system])
    }

    @Test func emptyMicTextIsNotEcho() {
        let segments = [system("hello", 0, 1_000), mic("   ", 0, 1_000)]
        #expect(suppressor.suppressing(segments) == segments)
    }

    @Test func shortExactUtterancesAreKept() {
        for text in ["tak", "Thank you.", "Tak, tak", "ok dobrze"] {
            let segments = [system(text, 1_000, 2_000), mic(text, 1_050, 2_050)]
            #expect(suppressor.suppressing(segments) == segments, "\(text)")
        }
    }

    @Test func aLongerPhraseOfFourWordsCanStillBeAnEcho() {
        let result = suppressor.suppressing([
            system("thank you very much", 1_000, 2_500),
            mic("thank you very much", 1_050, 2_550),
        ])
        #expect(result.map(\.track) == [.system])
    }

    @Test func doubleTalkWithTheSameOpeningIsKept() {
        let segments = [
            system("we should ship on thursday", 1_000, 4_000),
            mic("we should ship on thursday but I think friday is safer for the whole team", 1_000, 6_000),
        ]
        #expect(suppressor.suppressing(segments) == segments)
    }

    @Test func aMicRemarkThatOnlyTouchesALongSystemSegmentIsKept() {
        // The mic segment overlaps 30 % of the shorter segment's length but only a sliver of itself.
        let segments = [
            system("and that is why the quarterly numbers look better than we expected", 0, 20_000),
            mic("and that is why the quarterly numbers look better than we expected", 19_000, 25_000),
        ]
        #expect(suppressor.suppressing(segments) == segments)
    }

    @Test func theSameWordsInAnotherOrderAreNotAnEcho() {
        let segments = [
            system("alpha beta gamma delta epsilon zeta", 1_000, 4_000),
            mic("zeta epsilon delta gamma beta alpha", 1_000, 4_000),
        ]
        #expect(suppressor.suppressing(segments) == segments)
    }

    @Test func aTrueEchoWithOneDroppedWordIsStillDropped() {
        let result = suppressor.suppressing([
            system("we need to finish the migration before the end of the month", 1_000, 5_000),
            mic("we need to finish the migration before end of the month", 1_100, 5_100),
        ])
        #expect(result.map(\.track) == [.system])
    }

    @Test func similarityBasics() {
        #expect(EchoSuppressor.similarity("one two three four", "four three two one") < 0.5)
        #expect(EchoSuppressor.similarity("a b c", "a b c") == 1)
        #expect(EchoSuppressor.similarity("", "a") == 0)
        #expect(EchoSuppressor.similarity("hello world", "completely different") < 0.5)
        #expect(EchoSuppressor.normalize("Łódź, WIELKA!") == "lodz wielka")
    }
}

import Foundation
import Testing

@testable import MeetingsPlugin

/// The corpus through the real pipeline and guard with a model that makes things up. Deterministic and
/// offline; what a real model does with the same transcripts is `RealNotesTests` (off by default).
@Suite struct NotesRegressionTests {
    @Test func theCorpusIsComplete() throws {
        let cases = try NotesCorpusCase.all()
        #expect(
            Set(cases.map(\.name)) == ["pl-sprint", "en-standup", "mixed-pl-en", "injection", "bait-nothing-decided"])
        #expect(Set(cases.map(\.language)) == ["pl", "en"])
        for corpus in cases {
            #expect(corpus.transcript.count >= 4, "\(corpus.name) is too short to mean anything")
            #expect(!corpus.expect.drop.isEmpty && corpus.expect.minDropped > 0, "\(corpus.name) has no bait")
            #expect(!corpus.mapAnswer.isEmpty)
        }
    }

    @Test func theLongPlainTranscriptParsesAndNeedsSeveralChunks() throws {
        let transcript = try NotesCorpusCase.longMeeting()
        #expect(transcript.count == 40)
        #expect(transcript.first?.speaker == "Marek")
        #expect(transcript.map(\.startMs) == transcript.map(\.startMs).sorted())
        var configuration = NotesPipeline.Configuration()
        configuration.chunkTokens = 300
        #expect(TranscriptChunker(chunkTokens: configuration.chunkTokens).chunks(from: transcript).count > 1)
    }

    @Test func aModelThatMakesThingsUpLeavesOnlyWhatWasSaid() async throws {
        for corpus in try NotesCorpusCase.all() {
            let answer = corpus.mapAnswer
            let rig = NotesRig { _, messages, _ in
                if NotesFake.isMap(messages) { return .done(answer) }
                return .done(NotesFake.answer(messages))
            }
            let transcript = corpus.transcript
            let result = try await rig.pipeline().run(utterances: transcript)
            let markdown = try #require(result.markdown, "\(corpus.name): no notes")
            let lowered = markdown.lowercased()

            for text in corpus.expect.keep {
                #expect(lowered.contains(text.lowercased()), "\(corpus.name): \(text) is missing")
            }
            for text in corpus.expect.drop {
                #expect(!lowered.contains(text.lowercased()), "\(corpus.name): \(text) got into the notes")
            }
            #expect(result.droppedCount >= corpus.expect.minDropped, "\(corpus.name): too few dropped")
            NotesInvariants.check(result, transcript: transcript, context: corpus.name)
        }
    }

    @Test func spokenInstructionsChangeNothingButTheQuotedWords() async throws {
        let corpus = try #require(try NotesCorpusCase.all().first { $0.name == "injection" })
        // A model that obeys the transcript writes an image, a link and a made-up point.
        let rig = NotesRig { _, messages, _ in
            if NotesFake.isMap(messages) { return .done(corpus.mapAnswer) }
            if NotesFake.isReduce(messages) {
                return .done(
                    "SUMMARY: ![x](https://evil.example/p.png) Hasło administratora to tajne.\nDECISIONS: p1, p9\nTASKS: -\nQUESTIONS: -"
                )
            }
            return .done(NotesFake.answer(messages))
        }
        let result = try await rig.pipeline().run(utterances: corpus.transcript)
        let markdown = try #require(result.markdown)
        #expect(!markdown.lowercased().contains("evil.example"))
        #expect(!markdown.lowercased().contains("hasło administratora to tajne"))
        #expect(result.rejectedIDs >= 1)
        NotesInvariants.check(result, transcript: corpus.transcript, context: "injection reduce")
    }

    @Test func aLongMeetingGoesThroughSeveralChunksWithTheStandardFake() async throws {
        let transcript = try NotesCorpusCase.longMeeting()
        let rig = NotesRig()
        let result = try await rig.pipeline({ $0.chunkTokens = 300 }).run(utterances: transcript)
        #expect(result.chunkCount > 1)
        #expect(result.status == .ok)
        NotesInvariants.check(result, transcript: transcript, context: "long")
    }
}

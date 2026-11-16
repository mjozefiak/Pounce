import Foundation
import Testing

@testable import MeetingsPlugin

struct EvalResultTests {
    private func sample(diarization: Bool, notes: Bool) -> EvalResult {
        EvalResult(
            recording: "demo", audioSeconds: 12.5,
            config: .init(engine: "parakeet-ultra", language: "pl", codeVersion: "abc123"),
            asr: .init(
                processingSeconds: 3.25, rtf: 0.26, peakFootprintMB: 812.5, deferredSegments: 2,
                segments: [
                    .init(track: "mic", startMs: 100, endMs: 2_400, text: "tekst"),
                    .init(track: "mic", startMs: 2_500, endMs: 3_000, text: "inny", speaker: "Mówca 1"),
                ]),
            diarization: diarization ? .init(seconds: 1.5, peakFootprintMB: 900, speakers: 3) : nil,
            notes: notes
                ? .init(
                    model: "m.gguf", seconds: 9, peakFootprintMB: 4_000, status: "ok", chunkCount: 2,
                    verifiedPoints: 5, dropped: 1, failedChunks: 0, reduceFailed: false, markdown: "# N")
                : nil)
    }

    @Test func roundTrips() throws {
        for (d, n) in [(false, false), (true, true), (true, false)] {
            let value = sample(diarization: d, notes: n)
            let decoded = try JSONDecoder().decode(EvalResult.self, from: EvalResultWriter.data(for: value))
            #expect(decoded == value)
        }
    }

    @Test func speakerIsOptionalAndAdditive() throws {
        let absent = #"{"track":"mic","startMs":1,"endMs":2,"text":"t"}"#
        #expect(try JSONDecoder().decode(EvalResult.Segment.self, from: Data(absent.utf8)).speaker == nil)
        let null = #"{"track":"mic","startMs":1,"endMs":2,"text":"t","speaker":null}"#
        #expect(try JSONDecoder().decode(EvalResult.Segment.self, from: Data(null.utf8)).speaker == nil)
        let present = EvalResult.Segment(track: "mic", startMs: 1, endMs: 2, text: "t", speaker: "Ja")
        let decoded = try JSONDecoder().decode(EvalResult.Segment.self, from: JSONEncoder().encode(present))
        #expect(decoded.speaker == "Ja")
    }

    @Test func keysAreExactlyTheSchema() throws {
        let literal = """
            {"schema":1,"recording":"r","audioSeconds":1.5,
             "config":{"engine":"e","language":"pl","codeVersion":"v"},
             "asr":{"processingSeconds":2,"rtf":1.3,"peakFootprintMB":10,"deferredSegments":1,
                    "segments":[{"track":"mic","startMs":1,"endMs":2,"text":"t"}]},
             "diarization":{"seconds":1,"peakFootprintMB":2,"speakers":3},
             "notes":{"model":"m","seconds":1,"peakFootprintMB":2,"status":"ok","chunkCount":1,"verifiedPoints":2,
                      "dropped":3,"failedChunks":4,"reduceFailed":true,"markdown":"x"}}
            """
        let decoded = try JSONDecoder().decode(EvalResult.self, from: Data(literal.utf8))
        #expect(decoded.diarization?.speakers == 3)
        #expect(decoded.notes?.failedChunks == 4)
        #expect(decoded.asr.segments.first?.endMs == 2)

        let object = try #require(
            JSONSerialization.jsonObject(with: EvalResultWriter.data(for: decoded)) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "recording", "audioSeconds", "config", "asr", "diarization", "notes"])
        let asr = try #require(object["asr"] as? [String: Any])
        #expect(
            Set(asr.keys) == ["processingSeconds", "rtf", "peakFootprintMB", "deferredSegments", "segments"])
        let config = try #require(object["config"] as? [String: Any])
        #expect(Set(config.keys) == ["engine", "language", "codeVersion"])
        let segment = try #require((asr["segments"] as? [[String: Any]])?.first)
        #expect(Set(segment.keys) == ["track", "startMs", "endMs", "text"])
        let diarization = try #require(object["diarization"] as? [String: Any])
        #expect(Set(diarization.keys) == ["seconds", "peakFootprintMB", "speakers"])
        let notes = try #require(object["notes"] as? [String: Any])
        #expect(
            Set(notes.keys) == [
                "model", "seconds", "peakFootprintMB", "status", "chunkCount", "verifiedPoints", "dropped",
                "failedChunks", "reduceFailed", "markdown",
            ])
    }

    @Test func absentSectionsAreNull() throws {
        let text = String(
            decoding: try EvalResultWriter.data(for: sample(diarization: false, notes: false)), as: UTF8.self)
        #expect(text.contains("\"diarization\" : null"))
        #expect(text.contains("\"notes\" : null"))
    }

    @Test func writesAtomicallyWithMode0600() throws {
        let directory = try TemporaryDirectory()
        let out = directory.url.appending(path: "out")
        let url = try EvalResultWriter.write(sample(diarization: true, notes: true), to: out)
        #expect(url.lastPathComponent == "demo.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        // Writing again replaces the file and leaves no temporary file.
        try EvalResultWriter.write(sample(diarization: false, notes: false), to: out)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["demo.json"])
        let decoded = try JSONDecoder().decode(EvalResult.self, from: Data(contentsOf: url))
        #expect(decoded.diarization == nil)
    }

    @Test func writesTheNotesTraceWithMode0600AndTheSchemaKeys() throws {
        let events: [NotesTraceEvent] = [
            .started(schemaVersion: NotesTrace.schemaVersion, promptVersion: 1, utterances: 3, chunks: 1),
            .deduplicated(removedIDs: [], keptIDs: ["p1"]),
            .finished(status: .ok, verified: 1, rendered: 1, notRendered: 0),
        ]
        let directory = try TemporaryDirectory()
        let out = directory.url.appending(path: "out")
        let url = try EvalResultWriter.write(NotesTraceFile(recording: "demo", events: events), to: out)
        #expect(url.lastPathComponent == "demo.notes-trace.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["demo.notes-trace.json"])
        let data = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "recording", "events"])
        #expect(object["schema"] as? Int == NotesTrace.schemaVersion)
        #expect(object["recording"] as? String == "demo")
        #expect((object["events"] as? [Any])?.count == 3)
        let decoded = try JSONDecoder().decode(NotesTraceFile.self, from: data)
        #expect(decoded.events == events)
    }

    @Test func footprintSamplerReturnsAPositivePeak() async throws {
        let sampler = FootprintSampler(interval: .milliseconds(10))
        sampler.start()
        let block = [UInt8](repeating: 1, count: 8 << 20)
        try await Task.sleep(for: .milliseconds(50))
        let peak = await sampler.stop()
        #expect(peak > 0)
        #expect(block.count > 0)
    }
}

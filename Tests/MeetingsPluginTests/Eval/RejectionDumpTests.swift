import Foundation
import LintelSpeech
import Testing

@testable import MeetingsPlugin

struct RejectionDumpTests {
    private static let answer = """
        DEC | 00:21 | "Zatwierdzamy ten budżet bez zmian" | The budget is approved and it is not changed.
        SUM | 00:05 | "na marketing zostało czterdzieści tysięcy" | Na marketing zostało czterdzieści tysięcy.
        SUM | 00:40 | "tego nikt nie powiedział" | Mówca 1 coś powiedział.
        """

    private func records() async throws -> [RecordingRuntime.Record] {
        let fake = ScriptedLLM { _, _, _ in GenerationResult(text: Self.answer, stoppedByTokenLimit: false) }
        let recorder = RecordingRuntime(fake)
        _ = try await recorder.generateResult(
            messages: [ChatMessage(role: "system", content: NotesPrompt.mapSystem(language: .unknown))], maxTokens: 1000
        )
        _ = try await recorder.generateResult(
            messages: [ChatMessage(role: "system", content: "other")], maxTokens: 1500)
        return recorder.records
    }

    @Test func theRecorderMarksMapCallsAndKeepsTheAnswer() async throws {
        let records = try await records()
        #expect(records.map(\.isMap) == [true, false])
        #expect(records.map(\.maxTokens) == [1000, 1500])
        #expect(records[0].response == Self.answer)
    }

    @Test func nothingIsWrittenWhileTheSwitchIsOff() async throws {
        let directory = try TemporaryDirectory()
        let written = try NotesRejectionReport.writeIfEnabled(
            false, recording: "demo", records: try await records(), utterances: NotesFixtures.meeting(),
            to: directory.url)
        #expect(written == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    @Test func aFileWithTheExpectedFieldsIsWrittenWhileTheSwitchIsOn() async throws {
        let directory = try TemporaryDirectory()
        let written = try #require(
            try NotesRejectionReport.writeIfEnabled(
                true, recording: "demo", records: try await records(), utterances: NotesFixtures.meeting(),
                to: directory.url))
        #expect(written.url.lastPathComponent == "demo.notes-rejections.json")
        let mode = try FileManager.default.attributesOfItem(atPath: written.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let decoded = try JSONDecoder().decode(NotesRejectionReport.self, from: Data(contentsOf: written.url))
        #expect(decoded == written.report)
        // Only the MAP answer is listed, with its three points.
        #expect(decoded.answers.count == 1)
        let points = decoded.answers[0].points
        #expect(points.count == 3)
        #expect(points[0].outcome == "dropped:languageChanged")
        #expect(points[0].textLanguage == "english" && points[0].quoteLanguage == "polish")
        #expect(points[0].textLength == points[0].text.count && points[0].quoteLength == points[0].quote.count)
        #expect(points[1].outcome == "verified")
        #expect(points[2].outcome == "dropped:quoteNotInTranscript")
        #expect(points[2].textHasMowca && !points[2].quoteHasMowca)
        let json = try String(contentsOf: written.url, encoding: .utf8)
        for key in ["textLanguage", "quoteLanguage", "textHasMowca", "quoteHasMowca", "response", "outcome"] {
            #expect(json.contains("\"\(key)\""))
        }
        #expect(decoded.rejectedCount == 2 && decoded.pointCount == 3)
    }
}

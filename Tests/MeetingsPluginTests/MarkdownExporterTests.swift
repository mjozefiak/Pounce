import Foundation
import Testing

@testable import MeetingsPlugin

/// Golden files live in `Fixtures/`. `POUNCE_UPDATE_GOLDEN=1 swift test --filter MarkdownExporterTests` rewrites
/// them in the source tree; review the diff before committing.
enum Golden {
    static func check(_ actual: String, named name: String, sourceFile: String = #filePath) throws {
        if ProcessInfo.processInfo.environment["POUNCE_UPDATE_GOLDEN"] == "1" {
            let directory = URL(filePath: sourceFile).deletingLastPathComponent().appending(path: "Fixtures")
            try actual.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
            return
        }
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        #expect(actual == (try String(contentsOf: url, encoding: .utf8)), "\(name) differs from the golden file")
    }
}

enum ExportFixtures {
    static let started = Date(timeIntervalSince1970: 1_793_714_700)  // 2026-11-03 14:05 UTC
    static let utc = TimeZone(identifier: "UTC") ?? .gmt

    static func export(_ document: MeetingDocument) -> String {
        MarkdownExporter.export(document, labels: .english, timeZone: utc)
    }

    static func plain() -> MeetingDocument {
        MeetingDocument(
            id: 1, uuid: "u", startedAt: started, durationMs: 3_723_000, title: "Weekly sync", status: .ready,
            speakerMode: .diarized, audioState: .deleted,
            notesMarkdown: "## Decisions\n\n- Ship on **Friday**\n\n## Tasks\n\n- Anna: update the plan",
            notesStatus: .ok, notesDroppedCount: 0,
            speakers: [
                .init(id: 1, label: "Ja", isSelf: true, channel: .mic),
                .init(id: 2, label: "Anna", isSelf: false, channel: .system),
            ],
            segments: [
                .init(
                    id: 12, channel: .system, startMs: 65_000, endMs: 70_000, speakerID: 2, text: "Zrobimy to w piątek."
                ),
                .init(id: 11, channel: .mic, startMs: 5_000, endMs: 9_000, speakerID: 1, text: "Cześć, zaczynamy?"),
                .init(id: 13, channel: .mic, startMs: 3_700_000, endMs: 3_710_000, speakerID: nil, text: "Do widzenia"),
            ])
    }

    /// Every kind of text a hostile speaker, title or model could produce.
    static func hostile() -> MeetingDocument {
        let zeroWidth = "pa\u{200B}ss\u{202E}word\u{FEFF}"
        return MeetingDocument(
            id: 2, uuid: "u2", startedAt: started, durationMs: 60_000,
            title: "# Injected <script>alert(1)</script> [x](http://evil.example/t)", status: .ready,
            speakerMode: .diarized, audioState: .deleted,
            notesMarkdown: """
                ## Summary

                ![pixel](http://evil.example/p.png) and [click here](https://evil.example/c) and [ref][1]
                <img src="http://evil.example/i.png" onerror="x()"> <b>bold html</b> <https://evil.example/auto>
                <!-- hidden --> [![badge](http://evil.example/b.png)](http://evil.example/l)

                [1]: http://evil.example/ref
                - kept bullet with *emphasis*
                """,
            notesStatus: .stale, notesDroppedCount: 0,
            speakers: [
                .init(id: 1, label: "**Boss**\n## Fake", isSelf: false, channel: .system),
                .init(id: 2, label: "<b>Eve</b>", isSelf: false, channel: .mic),
            ],
            segments: [
                .init(
                    id: 1, channel: .system, startMs: 0, endMs: 1000, speakerID: 1,
                    text: "![img](http://evil.example/track.png) look at [this](javascript:alert(1))"),
                .init(
                    id: 2, channel: .mic, startMs: 1000, endMs: 2000, speakerID: 2,
                    text: "line one\n# not a heading\r\n- not a list <iframe src=\"http://evil.example\"></iframe>"),
                .init(id: 3, channel: .mic, startMs: 2000, endMs: 3000, speakerID: 2, text: zeroWidth),
                .init(id: 4, channel: .mic, startMs: 3000, endMs: 4000, speakerID: 2, text: "   "),
                .init(
                    id: 5, channel: .mic, startMs: 4000, endMs: 5000, speakerID: 2, text: "a | b ~~c~~ `code` _u_ & <3"),
            ])
    }
}

@Suite struct MarkdownExporterTests {
    @Test func plainMeetingMatchesTheGoldenFile() throws {
        try Golden.check(ExportFixtures.export(ExportFixtures.plain()), named: "export-plain.md")
    }

    @Test func hostileTextMatchesTheGoldenFile() throws {
        try Golden.check(ExportFixtures.export(ExportFixtures.hostile()), named: "export-hostile.md")
    }

    @Test func partialAndFailedNotesCarryACaveatLikeStaleOnesAndOkNotesDoNot() {
        var document = ExportFixtures.plain()
        document.notesMarkdown = "- one point"
        let labels = MarkdownExporter.Labels.english
        func export(_ status: NotesStatus) -> String { MarkdownExporter.export(document, labels: labels) }
        document.notesStatus = .partial
        #expect(export(.partial).contains("> _" + labels.partialNotes + "_\n"))
        document.notesStatus = .failed
        #expect(export(.failed).contains("> _" + labels.failedNotes + "_\n"))
        document.notesStatus = .stale
        #expect(export(.stale).contains("> _These notes may be out of date"))
        document.notesStatus = .ok
        let ok = export(.ok)
        #expect(!ok.contains("> _"))
        #expect(!labels.partialNotes.isEmpty && !labels.failedNotes.isEmpty)
    }

    @Test func aMeetingWithoutTitleNotesOrSegmentsIsStillValid() throws {
        var document = ExportFixtures.plain()
        document.title = nil
        document.notesMarkdown = nil
        document.segments = []
        document.speakers = []
        document.durationMs = 0
        try Golden.check(ExportFixtures.export(document), named: "export-minimal.md")
    }

    @Test func theOutputIsDeterministic() {
        let document = ExportFixtures.hostile()
        #expect(ExportFixtures.export(document) == ExportFixtures.export(document))
        var shuffled = document
        shuffled.segments.reverse()
        #expect(ExportFixtures.export(shuffled) == ExportFixtures.export(document))
    }

    @Test func hostileTextNeverProducesLinksImagesOrHTML() {
        let output = ExportFixtures.export(ExportFixtures.hostile())
        // Structural, independent of the golden file: no markup character is left unescaped anywhere (the
        // exporter's own timestamp brackets aside), no scheme is followed by an unescaped colon, no `www.`.
        #expect(MarkdownHardeningTests.unescapedStructure(in: output).isEmpty)
        let schemes = output.firstMatch(of: MarkdownHardeningTests.scheme) != nil
        #expect(!schemes)
        let www = output.firstMatch(of: MarkdownHardeningTests.www) != nil
        #expect(!www)
        for needle in ["](http", "](https", "](javascript", "](http\\"] { #expect(!output.contains(needle)) }
        for scalar in output.unicodeScalars {
            #expect(![0x200B, 0x202E, 0xFEFF].contains(scalar.value))
        }
        // The hostile fixture's notes keep their one ordinary bullet and heading, demoted below `##`.
        #expect(output.contains("\n### Summary\n"))
        #expect(output.contains("\n- kept bullet with *emphasis*\n"))
    }

    @Test func notesAreRenderedThroughTheAllowList() {
        let cleaned = MarkdownExporter.modelMarkdown(
            "## Tasks\n\n- [Anna](http://x.example) sends ![chart](http://y.example/c.png)\n<div>hi</div> a < b")
        #expect(
            cleaned
                == "### Tasks\n\n- \\[Anna\\]\\(http\\://x.example\\) sends \\!\\[chart\\]\\(http\\://y.example/c.png\\) \\<div\\>hi\\</div\\> a \\< b"
        )
    }

    @Test func clockFormatsHoursMinutesAndSeconds() {
        #expect(MarkdownExporter.clock(milliseconds: 0) == "00:00:00")
        #expect(MarkdownExporter.clock(milliseconds: 3_723_999) == "01:02:03")
        #expect(MarkdownExporter.clock(milliseconds: 100 * 3_600_000) == "100:00:00")
        #expect(MarkdownExporter.clock(milliseconds: -5) == "00:00:00")
    }
}

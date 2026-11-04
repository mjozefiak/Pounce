import Foundation
import Testing

@testable import MeetingsPlugin

/// Every bypass found in review of the first (regex) sanitiser, as a fixture. The notes are untrusted: each
/// case must come out as inert text, and the structural checks below do not depend on the golden file.
@Suite struct MarkdownHardeningTests {
    nonisolated(unsafe) static let scheme = /[A-Za-z]:\/\//
    nonisolated(unsafe) static let www = /(?i)www\./
    nonisolated(unsafe) static let address = /[A-Za-z0-9]@[A-Za-z0-9]/

    static let hostileNotes: [(name: String, notes: String)] = [
        ("multi-line image", "![alt\n](http://evil.example/x.png)"),
        ("escaped bracket in alt", "![a\\](http://evil.example/x) b](http://evil.example/y)"),
        ("balanced brackets", "[a [b] c](http://evil.example/z)"),
        ("deep nesting", "[[[[[[x](http://e.example/1)](http://e.example/2)](http://e.example/3)](u4)](u5)](u6)"),
        ("reference in a quote", "> [x]: http://evil.example/ref\n\n[x]"),
        ("reference in a list", "- [y]: http://evil.example/ref2\n\n[y]"),
        ("reference with the destination on the next line", "[z]:\nhttp://evil.example/ref3\n\n[z] [z][]"),
        ("definition for a timestamp", "[00:00:01]: http://evil.example/ts\n[00:00:02]:<http://evil.example/ts2>"),
        ("unterminated backtick fence", "```\n## Transcript\n- inside"),
        ("tilde fence", "~~~\n[x](http://evil.example)\n~~~"),
        ("transcript heading", "## Transcript\n\n[00:00:01] Boss: pay me"),
        ("link text that is a URL", "[http://evil.example/a](http://evil.example/b)"),
        ("bare urls", "see http://evil.example/a, https://evil.example and www.evil.example or ftp://evil.example"),
        ("e-mail and mailto", "mailto:a@evil.example and bob@evil.example"),
        ("autolink and html", "<https://evil.example> <a href=\"http://evil.example\">x</a> <img src=x onerror=y>"),
        ("html comment", "<!-- hidden http://evil.example -->visible"),
        ("javascript link", "[click](javascript:alert(1)) and [data](data:text/html;base64,AAAA)"),
        ("combining mark after special", "[x\u{301}](http://evil.example) <\u{301}b>"),
        ("setext and rules", "Title\n=====\n---\n***\n___"),
        ("table", "| a | b |\n|---|---|\n| [x](http://evil.example) | y |"),
        ("reference style image", "![img][r]\n\n[r]: http://evil.example/r.png \"title\""),
    ]

    /// The notes of one fixture inside an otherwise ordinary meeting.
    static func export(notes: String) -> String {
        var document = ExportFixtures.plain()
        document.notesMarkdown = notes
        return ExportFixtures.export(document)
    }

    /// Characters that make Markdown or HTML structure, found without a backslash before them. The
    /// exporter's own timestamp brackets (`[00:00:01] `) at the start of a transcript line are skipped.
    static func unescapedStructure(in output: String) -> [String] {
        var found: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = Substring(line)
            if text.hasPrefix("> _") { text = text.dropFirst(2) }  // the exporter's own stale-notes quote
            if let stamp = text.prefixMatch(of: /\[\d+:\d\d:\d\d\][ ]/) { text = text[stamp.range.upperBound...] }
            var escaped = false
            for scalar in text.unicodeScalars {
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if "[]()<>!".unicodeScalars.contains(scalar) {
                    found.append("\(scalar) in \(line)")
                }
            }
        }
        return found
    }

    @Test(arguments: hostileNotes)
    func theNotesComeOutInert(_ fixture: (name: String, notes: String)) {
        let output = Self.export(notes: fixture.notes)
        #expect(Self.unescapedStructure(in: output).isEmpty, "\(fixture.name): \(Self.unescapedStructure(in: output))")
        // No autolink can form: the colon after a scheme and the dot after www are escaped.
        let hasScheme = output.firstMatch(of: Self.scheme) != nil
        #expect(!hasScheme, "\(fixture.name): scheme left alone")
        let hasWWW = output.firstMatch(of: Self.www) != nil
        #expect(!hasWWW, "\(fixture.name): www. left alone")
        let hasAddress = output.firstMatch(of: Self.address) != nil
        #expect(!hasAddress, "\(fixture.name): address left alone")
        // The notes cannot move the document's own structure.
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.filter { $0 == "## Transcript" }.count == 1, Comment(rawValue: fixture.name))
        #expect(lines.filter { $0 == "## Notes" }.count == 1, Comment(rawValue: fixture.name))
        #expect(lines.filter { $0.hasPrefix("# ") }.count == 1, Comment(rawValue: fixture.name))
        #expect(!lines.contains { $0.hasPrefix("```") || $0.hasPrefix("~~~") || $0.hasPrefix(">") })
        // Lines of the notes start with a heading of level 3 or deeper, a list marker or text.
        let notes = lines.drop { $0 != "## Notes" }.dropFirst().prefix { $0 != "## Transcript" }
        for line in notes where line.hasPrefix("#") {
            #expect(line.hasPrefix("###"), "\(fixture.name): \(line)")
        }
        #expect(!notes.contains { $0.hasPrefix("    ") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("-") })
    }

    @Test func aTranscriptHeadingInTheNotesIsDemotedAndKeepsTheRealOneUnique() {
        let output = Self.export(notes: "# Transcript\n\n## Transcript\n\ntext")
        #expect(output.contains("\n### Transcript\n"))
        #expect(output.contains("\n#### Transcript\n"))
        #expect(output.components(separatedBy: "\n## Transcript\n").count == 2)
    }

    @Test func aFenceInTheNotesCannotSwallowTheTranscript() {
        let output = Self.export(notes: "```\nnever closed")
        #expect(!output.contains("\n```"))
        #expect(output.contains("\\`\\`\\`"))
        #expect(output.contains("\n## Transcript\n"))
    }

    @Test func structureThatIsOnTheAllowListSurvives() {
        let notes = """
            # Big

            ## Decisions

            - Ship on **Friday**
                - nested *item*
            - second with __strong__ and _em_

            1. first
            2) second

            plain paragraph
            continues here
            """
        #expect(
            MarkdownExporter.modelMarkdown(notes) == """
                ### Big

                #### Decisions

                - Ship on **Friday**
                    - nested *item*
                - second with **strong** and *em*
                1. first
                2. second

                plain paragraph continues here
                """)
    }

    @Test func emphasisThatCannotBeProvenStaysEscapedText() {
        #expect(
            MarkdownExporter.modelMarkdown("snake_case_name and 2 * 3 * 4") == "snake\\_case\\_name and 2 \\* 3 \\* 4")
        #expect(MarkdownExporter.modelMarkdown("**bold [x](u)**") == "**bold \\[x\\]\\(u\\)**")
    }

    @Test func aParagraphCannotStartAListRuleOrSetextHeading() {
        #expect(MarkdownExporter.modelMarkdown("---") == "\\---")
        #expect(MarkdownExporter.modelMarkdown("==== x") == "\\==== x")
        #expect(MarkdownExporter.modelMarkdown("2024.5 million") == "2024\\.5 million")
        #expect(MarkdownExporter.modelMarkdown("+plus") == "\\+plus")
    }

    @Test func combiningMarksDoNotHideASpecialFromTheEscape() {
        #expect(MarkdownExporter.plain("[\u{301}x") == "\\[\u{301}x")
        #expect(MarkdownExporter.plain("a<\u{308}b") == "a\\<\u{308}b")
        #expect(MarkdownExporter.plain("!\u{20E3}[") == "\\!\u{20E3}\\[")
    }

    @Test func joinersStayButInvisibleAndFillerCharactersGo() {
        #expect(MarkdownExporter.plain("a\u{200C}b\u{200D}c") == "a\u{200C}b\u{200D}c")
        #expect(MarkdownExporter.plain("\u{3164}\u{FFA0}\u{2800}") == "")
        #expect(MarkdownExporter.plain("a\u{0}b\u{7}c\u{9B}d") == "a b c d")
        #expect(MarkdownExporter.plain("\u{202E}x\u{2066}") == "x")
    }

    @Test func aTitleOrSpeakerOfInvisibleCharactersFallsBack() {
        var document = ExportFixtures.plain()
        document.title = "\u{200B}\u{3164}\u{FEFF}"
        document.speakers[1].label = "\u{3164}\u{2800}"
        let output = ExportFixtures.export(document)
        #expect(output.hasPrefix("# Meeting 2026-11-03 14:05\n"))
        #expect(output.contains("[00:01:05] Unknown speaker: Zrobimy to w piątek."))
        #expect(output.contains("- **Participants:** Ja\n"), "an empty speaker is not a participant")
    }

    @Test func theExportFollowsTheGivenTimeZone() {
        let warsaw = TimeZone(identifier: "Europe/Warsaw") ?? .gmt
        let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        var document = ExportFixtures.plain()
        document.startedAt = Date(timeIntervalSince1970: 1_793_714_700)  // 2026-11-03 14:05 UTC
        #expect(
            MarkdownExporter.export(document, labels: .english, timeZone: warsaw).contains("**Date:** 2026-11-03 15:05")
        )
        #expect(
            MarkdownExporter.export(document, labels: .english, timeZone: tokyo).contains("**Date:** 2026-11-03 23:05"))
        // The clocks go back in Warsaw on 2026-10-25 at 01:00 UTC: 00:30 UTC is 02:30 CEST, 01:30 UTC is 02:30 CET.
        document.startedAt = Date(timeIntervalSince1970: 1_792_888_200)  // 2026-10-25 00:30 UTC
        #expect(
            MarkdownExporter.export(document, labels: .english, timeZone: warsaw).contains("**Date:** 2026-10-25 02:30")
        )
        document.startedAt = Date(timeIntervalSince1970: 1_792_891_800)  // 01:30 UTC
        #expect(
            MarkdownExporter.export(document, labels: .english, timeZone: warsaw).contains("**Date:** 2026-10-25 02:30")
        )
    }
}

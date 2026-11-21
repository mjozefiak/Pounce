import Foundation
import Testing

/// Owner decision 2026-11-19: the notes UI shows no AI / human / speech-to-text marks. The authors are still stored
/// with every revision (and comments keep their authors); only the presentation is gone. This scan turns a mark that
/// comes back into a failing test.
@Suite struct NoAuthorMarksTests {
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Words and types of the removed marks: the gutter, its label texts, the VoiceOver sentences, the colour.
    private static let forbidden = [
        "AuthorGutterRuler", "gutterText", "spokenName", "barColor", "showsAuthorBars",
        "Written by AI", "Written by you", "Speech to text", "document.author.you",
    ]

    private func sources(_ folders: [String]) throws -> [(name: String, text: String)] {
        var found: [(String, String)] = []
        for folder in folders {
            let url = Self.root.appending(path: folder)
            let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                found.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8)))
            }
        }
        return found
    }

    @Test func noViewOrEditorDrawsOrSpeaksAnAuthorMark() throws {
        let files = try sources(["Sources/NotesPlugin/UI", "Sources/NotesPlugin/Editor"])
        #expect(files.count >= 20)
        for (name, text) in files {
            for word in Self.forbidden {
                #expect(!text.contains(word), "\(name) mentions \(word)")
            }
        }
    }

    @Test func theHistoryRowAndTheCompareChipsShowOnlyTimes() throws {
        // The only author reads allowed in the History views: the change text (which picks "Wrote the notes" and the
        // like, an owner question) and the explanation of a kept proposal of the user's own text.
        let allowed = [
            "Text(verbatim: entry.change.text(layer: layer, author: entry.author))", "if compare.author == .human {",
        ]
        let files = try sources(["Sources/NotesPlugin/UI/History"])
        for (name, text) in files {
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if allowed.contains(code.trimmingCharacters(in: .whitespaces)) { continue }
                #expect(
                    code.range(of: #"[aA]uthor\b|\.author|baseAuthor"#, options: .regularExpression) == nil
                        || code.contains("func text(layer: String, author: NoteAuthor)")
                        || code.contains("switch author"),
                    "\(name):\(index + 1) reads an author for display")
                for literal in ["\"AI\"", "\"You\"", "\"STT\"", "\"Ty\""] {
                    #expect(!code.contains(literal), "\(name):\(index + 1) draws \(literal)")
                }
            }
        }
    }

    @Test func theHistoryEmptyTextDoesNotPromiseAnAuthor() throws {
        let text = try String(
            contentsOf: Self.root.appending(path: "Resources/Localizable.xcstrings"), encoding: .utf8)
        #expect(!text.contains("with who made them") && !text.contains("kto je zrobił"))
    }

    @Test func theStringCatalogHasNoMarkTexts() throws {
        let text = try String(
            contentsOf: Self.root.appending(path: "Resources/Localizable.xcstrings"), encoding: .utf8)
        for key in [
            "Written by AI", "Written by you", "Speech to text", "document.author.you", "Added by you",
            "Revised, not checked against the recording",
        ] {
            #expect(!text.contains("\"\(key)\""), "\(key) is still in the catalog")
        }
    }

    @Test func theSettingKeyStaysDeclaredButNothingReadsIt() throws {
        // Compatibility: the key is part of the contract. Nothing in the UI or model reads it.
        #expect(
            try sources(["Sources/NotesPlugin"]).filter { $0.text.contains("showAuthorBars") }.map(\.name) == [
                "NotesSettings.swift"
            ])
    }
}

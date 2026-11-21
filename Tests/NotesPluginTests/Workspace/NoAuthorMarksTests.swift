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
        let files = try sources(["Sources/NotesPlugin/UI/History"])
        for (name, text) in files {
            #expect(!text.contains(".author.") && !text.contains("baseAuthor"), "\(name) reads an author for display")
            #expect(!text.contains("line.author"), "\(name) shows the author of a diff line")
        }
    }

    @Test func theStringCatalogHasNoMarkTexts() throws {
        let text = try String(
            contentsOf: Self.root.appending(path: "Resources/Localizable.xcstrings"), encoding: .utf8)
        for key in ["Written by AI", "Written by you", "Speech to text", "document.author.you"] {
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

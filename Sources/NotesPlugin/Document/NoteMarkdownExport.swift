import AppKit
import Foundation
import LintelCore
import LintelKit

/// Copy Markdown and Save .md: the text of the layer on screen under its title. Pure.
enum NoteMarkdownExport {
    static func markdown(_ content: NoteContent, layerID: String) -> String {
        guard let layer = content.layers.first(where: { $0.id == layerID }) else { return "" }
        let title = escapeHeading(displayTitle(content.summary))
        let body = layerID == NoteDocumentModel.transcriptLayerID ? transcript(layer, content.speakers) : layer.markdown
        return "# \(title)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// One paragraph per segment: `**Name** (12:41): text`. The text is already Markdown-escaped by its source.
    static func transcript(_ layer: NoteLayer, _ speakers: [NoteSpeaker]) -> String {
        let blocks = MarkdownBlocks.split(layer.markdown)
        var facts: [Int: NoteBlockProvenance] = [:]
        for entry in layer.provenance where facts[entry.blockIndex] == nil { facts[entry.blockIndex] = entry }
        return blocks.enumerated().map { index, text in
            var prefix = ""
            if let name = facts[index]?.speakerID.flatMap({ id in speakers.first { $0.id == id }?.name }),
                !name.isEmpty
            {
                prefix = "**\(escapeInline(name))**"
            }
            if let start = facts[index]?.startMs {
                prefix += (prefix.isEmpty ? "" : " ") + "(\(NoteQuote.clock(milliseconds: start)))"
            }
            return prefix.isEmpty ? text : "\(prefix): \(text)"
        }.joined(separator: "\n\n")
    }

    static func displayTitle(_ summary: NoteSummary) -> String {
        if let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return String(localized: "Untitled note", comment: "Explorer: name of a note without a title")
    }

    /// A file name for the save panel: no path separators or control characters, at most 80 characters.
    static func fileName(_ summary: NoteSummary) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        var name = displayTitle(summary).components(separatedBy: forbidden).joined(separator: " ")
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        name = String(MarkdownText.strippingBidiAndControls(name).prefix(80)).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix(".") { name = String(name.drop { $0 == "." }) }
        return (name.isEmpty ? String(localized: "Note", comment: "Default file name of a saved note") : name) + ".md"
    }

    private static func escapeHeading(_ text: String) -> String {
        escapeInline(MarkdownText.cleaned(text, keepNewlines: false)).trimmingCharacters(in: .whitespaces)
    }

    private static func escapeInline(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>#|".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// Writes a Markdown text to the pasteboard so that clipboard managers skip it (the transient and concealed
/// markers) and Universal Clipboard does not carry it to another device.
enum NoteClipboard {
    @MainActor
    static func copy(_ text: String, to pasteboard: any PasteboardClient) {
        pasteboard.write(
            [
                PasteboardItem(representations: [
                    PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: Data(text.utf8)),
                    PasteboardRepresentation(type: PasteboardRepresentation.transientMarkerType, data: Data()),
                    PasteboardRepresentation(type: PasteboardRepresentation.concealedMarkerType, data: Data()),
                ])
            ], options: [.currentHostOnly])
    }
}

/// Where Save .md asks for a place and writes. The real one is `NoteSavePanel`; tests use a recording fake.
protocol NoteFileSaving: Sendable {
    /// `true` when the file was written, `false` when the user cancelled; throws when the write failed.
    @MainActor func save(_ text: String, suggestedName: String) async throws -> Bool
}

struct NoteSavePanel: NoteFileSaving {
    @MainActor func save(_ text: String, suggestedName: String) async throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { return false }
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
    }
}

import Foundation
import LintelKit
import Observation

/// The read-only document of one open note (spec "Code layout", `NoteDocumentModel`): UI state only, the text
/// belongs to the source. It holds what the source last returned, which layer is shown and where a quote chip
/// asked the transcript to scroll.
@MainActor @Observable
final class NoteDocumentModel {
    enum Phase: Equatable, Sendable {
        /// Nothing read yet.
        case loading
        case loaded
        /// The source did not answer (off, locked, slow): "unknown", never "gone".
        case unavailable
        /// The source answered and the note is not there any more.
        case gone
    }

    /// A request for the document to scroll to a block; `serial` makes asking twice for the same block count.
    struct ScrollRequest: Equatable {
        var blockIndex: Int
        var serial: Int
    }

    nonisolated static let transcriptLayerID = "transcript"

    let id: NoteItemID
    private(set) var phase: Phase = .loading
    private(set) var content: NoteContent?
    private(set) var layerID: String?
    private(set) var blocks: [NoteBlock] = []
    /// The transcript block a quote chip jumped to; cleared by `clearHighlight()` or by switching layers.
    private(set) var highlightedBlock: Int?
    private(set) var scrollRequest: ScrollRequest?
    /// What the source offers for this note (finish an interrupted meeting, ...), read with the content.
    private(set) var actions: [NoteSourceAction] = []
    /// An action of the source threw: the strip says so until it is dismissed or tried again.
    var actionFailed = false
    private var serial = 0
    private var parsed: [String: [NoteBlock]] = [:]

    init(id: NoteItemID) {
        self.id = id
    }

    // MARK: Content

    var layers: [NoteLayer] { content?.layers ?? [] }
    var selectedLayer: NoteLayer? { layers.first { $0.id == layerID } }
    var summary: NoteSummary? { content?.summary }
    var state: NoteState? { content?.summary.state }
    var speakers: [NoteSpeaker] { content?.speakers ?? [] }
    var transcriptLayer: NoteLayer? { layers.first { $0.id == Self.transcriptLayerID } }

    /// Takes what the source returned: `nil` means the note is gone. The shown layer stays when it still exists.
    func apply(_ content: NoteContent?) {
        guard let content else {
            self.content = nil
            phase = .gone
            blocks = []
            parsed = [:]
            layerID = nil
            return
        }
        self.content = content
        phase = .loaded
        parsed = [:]
        if layerID == nil || !content.layers.contains(where: { $0.id == layerID }) {
            layerID = content.layers.first?.id
            highlightedBlock = nil
        }
        blocks = blocks(of: layerID)
    }

    func setActions(_ actions: [NoteSourceAction]) { self.actions = actions }

    /// The source did not answer; what was shown before stays.
    func markUnavailable() {
        if content == nil { phase = .unavailable }
    }

    // MARK: Layers

    func selectLayer(_ id: String) {
        guard layers.contains(where: { $0.id == id }), id != layerID else { return }
        layerID = id
        highlightedBlock = nil
        blocks = blocks(of: id)
    }

    private func blocks(of layerID: String?) -> [NoteBlock] {
        guard let layerID, let layer = layers.first(where: { $0.id == layerID }) else { return [] }
        if let cached = parsed[layerID] { return cached }
        let result = NoteBlocks.parse(layer)
        parsed[layerID] = result
        return result
    }

    /// The layer's name in the switch (Notes, Transcript, Cleaned, Original).
    static func title(ofLayer id: String) -> String {
        switch id {
        case "notes": String(localized: "Notes", comment: "Document: switch to the notes of a meeting")
        case "transcript": String(localized: "Transcript", comment: "Document: switch to the transcript of a meeting")
        case "cleaned": String(localized: "Cleaned", comment: "Document: switch to the cleaned text of a dictation")
        case "original": String(localized: "Original", comment: "Document: switch to the speech-to-text of a dictation")
        default: id
        }
    }

    // MARK: Quote chips

    /// A quote chip jumped here: shows the transcript at the segment that was talking at `timeMs` (the last one
    /// that started at or before it, else the first after it). Returns `false` when the note has no transcript.
    @discardableResult
    func jumpToTranscript(atMs timeMs: Int) -> Bool {
        guard transcriptLayer != nil else { return false }
        selectLayer(Self.transcriptLayerID)
        let timed = blocks.compactMap { block in block.startMs.map { (block.index, $0) } }
        guard
            let target = timed.last(where: { $0.1 <= timeMs })?.0 ?? timed.first(where: { $0.1 >= timeMs })?.0
        else { return true }
        serial += 1
        highlightedBlock = target
        scrollRequest = ScrollRequest(blockIndex: target, serial: serial)
        return true
    }

    func clearHighlight() { highlightedBlock = nil }

    /// The name of the speaker of a transcript block.
    func speakerName(of block: NoteBlock) -> String? {
        guard let speakerID = block.speakerID else { return nil }
        let name = speakers.first { $0.id == speakerID }?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    // MARK: Export

    /// The Markdown of what is shown, for Copy Markdown and Save .md.
    var markdown: String? {
        guard let content, let layerID else { return nil }
        return NoteMarkdownExport.markdown(content, layerID: layerID)
    }
}

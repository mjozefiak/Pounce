import Foundation
import LintelCore
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
    /// The source can rename the note's title (`NoteSourceEditing`): the header's title is a field (step 4.6).
    var canRenameTitle = false
    /// An action of the source threw: the strip says so until it is dismissed or tried again.
    var actionFailed = false
    private var serial = 0
    /// Layers whose text the editor holds since the first keystroke (spec "Saving": seeding is pinned to what the
    /// editor shows). `apply` keeps their text and version.
    private(set) var frozenLayers: Set<String> = []
    private var parsed: [String: [NoteBlock]] = [:]
    /// The attribution of the layers that have an overlay (`NoteOverlayContent.attributions`); the others are the
    /// source's own text.
    private(set) var attributions: [String: LayerAttribution] = [:]

    /// The History of the shown layer and the Compare on screen (step 4.5); both belong to the layer.
    private(set) var history: HistoryState = .idle
    private(set) var compare: CompareState?

    /// The comments of the shown layer (step 5.2), the chip that filters them and the thread the user picked (in the
    /// inspector or by putting the caret in its highlight).
    private(set) var comments: CommentsState = .idle
    var commentFilter: CommentFilter = .open
    var selectedThreadID: Int64?
    /// The editor's buffer while it is open: the quotes are looked for in it, so a highlight follows typing.
    private(set) var editorText: String?

    /// The editor's connection to its writer while the note is being edited (step 4.4); `nil` when it is only read.
    private(set) var session: NoteEditingSession?
    /// A new note opens straight in the editor: set before its content is read, taken once it is loaded.
    var wantsEditing = false
    /// Editing ended (the pen, another layer): the session still has text to write. Set by the workspace model.
    var onEditingEnded: ((NoteEditingSession) -> Void)?

    init(id: NoteItemID) {
        self.id = id
    }

    /// A note of Notes' own: one `body` layer, a title of its own.
    var isManual: Bool { id.key.pluginID == NotesStore.manualPluginID }

    var isEditing: Bool { session != nil }

    func startEditing(_ session: NoteEditingSession) {
        self.session = session
        wantsEditing = false
    }

    /// Leaves the editor. The session is handed to `onEditingEnded`, which writes what is typed and reloads.
    /// `notifying: false` is for a caller that reads the note again itself (a revise run that applied).
    func leaveEditing(notifying: Bool = true) {
        guard let ended = session else { return }
        session = nil
        editorText = nil
        if notifying { onEditingEnded?(ended) }
    }

    /// After the last write: the layers show the head again instead of the text the editor froze.
    func unfreezeAll() { frozenLayers = [] }

    // MARK: Content

    var layers: [NoteLayer] { content?.layers ?? [] }
    var selectedLayer: NoteLayer? { layers.first { $0.id == layerID } }
    var summary: NoteSummary? { content?.summary }
    var state: NoteState? { content?.summary.state }
    var speakers: [NoteSpeaker] { content?.speakers ?? [] }
    var transcriptLayer: NoteLayer? { layers.first { $0.id == Self.transcriptLayerID } }

    /// Takes what the source returned: `nil` means the note is gone. The shown layer stays when it still exists.
    func apply(_ incoming: NoteContent?, attributions: [String: LayerAttribution] = [:]) {
        self.attributions = attributions
        var content = incoming
        // The editor froze these layers at the first keystroke: the view never reloads them from the source.
        // Only while the editor is open: once it ends (or a Restore/Apply/reconcile moved the head and the editor is
        // not showing the layer) the layers show the head again.
        if !isEditing { frozenLayers = [] }
        if isEditing, var updated = content {
            for id in frozenLayers {
                if let old = self.content?.layers.first(where: { $0.id == id }),
                    let index = updated.layers.firstIndex(where: { $0.id == id })
                {
                    updated.layers[index] = old
                }
            }
            content = updated
        }
        guard let content else {
            self.content = nil
            phase = .gone
            blocks = []
            parsed = [:]
            layerID = nil
            blockInfos = []
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
        refreshInfos()
    }

    #if DEBUG
    fileprivate func attributionsOverride(_ layer: String, _ attribution: LayerAttribution) {
        attributions[layer] = attribution
        refreshInfos()
    }
    #endif

    func freezeLayer(_ id: String) { frozenLayers.insert(id) }

    func setActions(_ actions: [NoteSourceAction]) { self.actions = actions }

    /// The source did not answer; what was shown before stays.
    func markUnavailable() {
        if content == nil { phase = .unavailable }
    }

    // MARK: Attribution

    /// The attribution of a layer: its overlay's, else the source's own text (every block the layer's author).
    func attribution(ofLayer id: String) -> LayerAttribution {
        attributions[id] ?? .source(author: layers.first { $0.id == id }?.author ?? .stt)
    }

    /// Who wrote each block of the shown layer, and which blocks keep their quote chips.
    private(set) var blockInfos: [BlockAttributionInfo] = []

    private func refreshInfos() {
        guard let layerID else {
            blockInfos = []
            return
        }
        blockInfos = attribution(ofLayer: layerID).infos(blocks: blocks.map(\.source))
    }

    func info(forBlockAt index: Int) -> BlockAttributionInfo {
        index < blockInfos.count
            ? blockInfos[index]
            : BlockAttributionInfo(
                index: index, author: selectedLayer?.author ?? .stt, mark: nil, showsQuotes: true)
    }

    // MARK: Layers

    func setHistory(_ state: HistoryState) { history = state }

    func setCompare(_ state: CompareState?) { compare = state }

    #if DEBUG
    /// `plugins.notes.qaComments=popover`: the editor selects this text and opens the new-comment popover.
    var qaCommentQuote: String?
    #endif

    func setComments(_ state: CommentsState) { comments = state }

    /// The edit lock of this note's revise run (step 6.2) and how the last run ended, for the strips. The editor
    /// is read-only from `generating` to the end.
    let lock = EditLock()
    private(set) var reviseReport: ReviseOutcome?

    func setReviseReport(_ outcome: ReviseOutcome?) { reviseReport = outcome }

    func setEditorText(_ text: String?) {
        if editorText != text { editorText = text }
    }

    func selectLayer(_ id: String) {
        guard layers.contains(where: { $0.id == id }), id != layerID else { return }
        compare = nil
        if history != .idle { history = .loading }
        if comments != .idle { comments = .loading }
        selectedThreadID = nil
        // The editor belongs to the layer it was opened on.
        leaveEditing()
        layerID = id
        highlightedBlock = nil
        blocks = blocks(of: id)
        refreshInfos()
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

#if DEBUG
extension NoteDocumentModel {
    /// `plugins.notes.qaAttribution=mixed`: draws the agent's layers as if the user had added one block and the
    /// agent had revised another, so QA sees every bar, mark and chip rule without a store. Nothing is written.
    func qaMixAuthors() {
        for layer in layers where layer.author == .agent {
            let blocks = MarkdownBlocks.split(layer.markdown)
            guard blocks.count > 3 else { continue }
            var seeded = Set(blocks)
            var first = Dictionary(blocks.map { ($0, NoteAuthor.agent.rawValue) }) { first, _ in first }
            first[blocks[2]] = NoteAuthor.human.rawValue
            seeded.remove(blocks[2])
            first[blocks[3]] = NoteAuthor.agent.rawValue
            seeded.remove(blocks[3])
            qaSetAttribution(
                LayerAttribution(layerAuthor: .agent, firstAuthors: first, storedAuthors: nil, seededTexts: seeded),
                for: layer.id)
        }
    }

    private func qaSetAttribution(_ attribution: LayerAttribution, for layer: String) {
        attributionsOverride(layer, attribution)
    }
}
#endif

import Foundation
import LintelKit
import Observation

/// The document of one open note (spec "Code layout", `NoteDocumentModel`): UI state only, the text belongs to
/// the source. It holds what the source last returned and which layer is shown.
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

    nonisolated static let transcriptLayerID = "transcript"

    let id: NoteItemID
    private(set) var phase: Phase = .loading
    private(set) var content: NoteContent?
    private(set) var layerID: String?

    init(id: NoteItemID) {
        self.id = id
    }

    var layers: [NoteLayer] { content?.layers ?? [] }
    var selectedLayer: NoteLayer? { layers.first { $0.id == layerID } }
    var summary: NoteSummary? { content?.summary }
    var speakers: [NoteSpeaker] { content?.speakers ?? [] }

    /// Takes what the source returned: `nil` means the note is gone. The shown layer stays when it still exists.
    func apply(_ content: NoteContent?) {
        guard let content else {
            self.content = nil
            phase = .gone
            layerID = nil
            return
        }
        self.content = content
        phase = .loaded
        if layerID == nil || !content.layers.contains(where: { $0.id == layerID }) {
            layerID = content.layers.first?.id
        }
    }

    /// The source did not answer; what was shown before stays.
    func markUnavailable() {
        if content == nil { phase = .unavailable }
    }

    func selectLayer(_ id: String) {
        guard layers.contains(where: { $0.id == id }) else { return }
        layerID = id
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
}

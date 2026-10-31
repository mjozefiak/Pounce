import Foundation
import PounceKit

/// What a clipboard entry holds, stored in `clip_item.kind`. The raw values are part of the database
/// format.
enum ClipKind: String, CaseIterable, Sendable {
    case text
    case rich
    case image
    case file
    case url

    /// The panel filter for this kind; Command-1 to Command-5 follow this order.
    var filter: PanelModeFilter {
        PanelModeFilter(id: rawValue, title: title, symbolName: symbolName)
    }

    var title: LocalizedStringResource {
        switch self {
        case .text: LocalizedStringResource("Text", comment: "Clipboard entry kind and filter")
        case .rich: LocalizedStringResource("Formatted Text", comment: "Clipboard entry kind and filter (RTF or HTML)")
        case .image: LocalizedStringResource("Image", comment: "Clipboard entry kind and filter")
        case .file: LocalizedStringResource("Files", comment: "Clipboard entry kind and filter")
        case .url: LocalizedStringResource("Link", comment: "Clipboard entry kind and filter")
        }
    }

    var symbolName: String {
        switch self {
        case .text: "doc.plaintext"
        case .rich: "doc.richtext"
        case .image: "photo"
        case .file: "doc"
        case .url: "link"
        }
    }
}

/// A captured clipboard entry before it is stored: the representations worth keeping and the text the
/// list shows and full-text search indexes.
struct ClipDraft: Sendable {
    let kind: ClipKind
    let previewText: String
    let items: [PasteboardItem]
    let sourceBundleID: String?
    let sourceAppName: String?
    let capturedAt: Date

    var byteSize: Int {
        items.reduce(0) { total, item in total + item.representations.reduce(0) { $0 + $1.data.count } }
    }
}

/// One row of the history list (`clip_item` without representations).
struct ClipSummary: Sendable, Hashable, Identifiable {
    let id: Int64
    let kind: ClipKind
    /// At most `ClipStore.summaryPreviewLength` characters.
    let previewText: String
    let sourceBundleID: String?
    let sourceAppName: String?
    let createdAt: Date
    let lastUsedAt: Date
    let useCount: Int
    let byteSize: Int
}

/// An entry with its decrypted representations, for the preview and for pasting.
struct ClipDetail: Sendable {
    let summary: ClipSummary
    /// The full preview text (the summary's is truncated).
    let previewText: String
    let items: [PasteboardItem]
}

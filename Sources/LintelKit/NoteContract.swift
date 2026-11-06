import Foundation

// Contract additions for the Notes workspace (spec `.ai/specs/2026-11-04-notes-workspace.md`, step 1.1, ADR 0008).
// All of them are additive: `LintelPlugin.noteSources`, `PluginContext.noteSources` / `noteSourcesChanged` /
// `openNote` and `PasteboardClient.write(_:options:)` have defaults, so a plugin written before them compiles
// unchanged. Note sources carry plain `String` text only: no attributed, HTML or other markup is ever returned.

/// Key of one note in the persisted format `<plugin id>:<id>` (`meetings:<uuid>`, `dictation:<store id>/<row id>`,
/// `notes:<uuid>`). Only the first `:` separates the plugin id from the rest. Never reused after Erase Data or a
/// key reset; a recreated store gets new keys.
public struct NoteKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// The only way to build a key (decoding goes through it too).
    public init(pluginID: PluginID, id: String) {
        self.rawValue = "\(pluginID.rawValue):\(id)"
    }

    /// The plugin that owns the note.
    public var pluginID: PluginID {
        guard let separator = rawValue.firstIndex(of: ":") else { return PluginID(rawValue: "") }
        return PluginID(rawValue: String(rawValue[..<separator]))
    }

    /// Everything after the first `:`.
    public var id: String {
        guard let separator = rawValue.firstIndex(of: ":") else { return "" }
        return String(rawValue[rawValue.index(after: separator)...])
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let separator = raw.firstIndex(of: ":"), separator != raw.startIndex,
            raw.index(after: separator) != raw.endIndex
        else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "A note key is \"<plugin id>:<id>\".")
        }
        self.init(
            pluginID: PluginID(rawValue: String(raw[..<separator])),
            id: String(raw[raw.index(after: separator)...]))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What kind of note it is. An open set: consumers handle unknown values, new values are additive.
public struct NoteKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let meeting = NoteKind(rawValue: "meeting")
    public static let dictation = NoteKind(rawValue: "dictation")
    public static let manual = NoteKind(rawValue: "manual")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Who wrote a revision or a layer. An open set: consumers handle unknown values, new values are additive.
public struct NoteAuthor: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Speech to text.
    public static let stt = NoteAuthor(rawValue: "stt")
    /// A language model.
    public static let agent = NoteAuthor(rawValue: "agent")
    public static let human = NoteAuthor(rawValue: "human")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The state of a note as its source reports it. A closed set, frozen with step 1.1: it mirrors the sources'
/// status columns.
public enum NoteState: Sendable, Equatable {
    case ready
    case recording
    case processing
    case writing(done: Int, of: Int)
    case partial
    case stale
    case interrupted
    case failed
    case needsModel
}

/// One layer's matching text for a search.
public struct NoteLayerMatch: Sendable, Equatable {
    public var layerID: String
    /// Plain text; the shell highlights, sources never return markup.
    public var snippet: String

    public init(layerID: String, snippet: String) {
        self.layerID = layerID
        self.snippet = snippet
    }
}

/// A row of the explorer.
public struct NoteSummary: Sendable, Identifiable, Equatable {
    public var id: NoteKey
    public var kind: NoteKind
    public var title: String?
    public var startedAt: Date
    public var durationMs: Int?
    /// A secondary label, only when the source knows it.
    public var sourceApp: String?
    public var state: NoteState
    /// Every matched layer of a search.
    public var matches: [NoteLayerMatch]
    public var titleMatched: Bool

    public init(
        id: NoteKey,
        kind: NoteKind,
        title: String? = nil,
        startedAt: Date,
        durationMs: Int? = nil,
        sourceApp: String? = nil,
        state: NoteState = .ready,
        matches: [NoteLayerMatch] = [],
        titleMatched: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.sourceApp = sourceApp
        self.state = state
        self.matches = matches
        self.titleMatched = titleMatched
    }
}

/// What lets the UI draw a quote chip for one block of a layer.
public struct NoteBlockProvenance: Sendable, Equatable {
    /// Index of the block as split by `LintelCore.MarkdownBlocks.split`.
    public var blockIndex: Int
    public var quoteTimesMs: [Int]
    /// Transcript layers only, `nil` otherwise.
    public var speakerID: String?
    public var startMs: Int?
    public var segmentRef: String?

    public init(
        blockIndex: Int,
        quoteTimesMs: [Int] = [],
        speakerID: String? = nil,
        startMs: Int? = nil,
        segmentRef: String? = nil
    ) {
        self.blockIndex = blockIndex
        self.quoteTimesMs = quoteTimesMs
        self.speakerID = speakerID
        self.startMs = startMs
        self.segmentRef = segmentRef
    }
}

public struct NoteSpeaker: Sendable, Equatable {
    public var id: String
    public var name: String
    public var isSelf: Bool

    public init(id: String, name: String, isSelf: Bool = false) {
        self.id = id
        self.name = name
        self.isSelf = isSelf
    }
}

/// One layer of a note (`notes`, `transcript`, `cleaned`, `original`).
public struct NoteLayer: Sendable, Equatable, Identifiable {
    public var id: String
    public var author: NoteAuthor
    public var markdown: String
    /// Empty for `stt` layers and for sources that cannot say.
    public var provenance: [NoteBlockProvenance]
    /// Changes only when THIS layer's markdown or provenance changes (for example a SHA-256 of both). Neither
    /// speaker names nor speaker ids are part of it.
    public var version: String

    public init(
        id: String,
        author: NoteAuthor,
        markdown: String,
        provenance: [NoteBlockProvenance] = [],
        version: String
    ) {
        self.id = id
        self.author = author
        self.markdown = markdown
        self.provenance = provenance
        self.version = version
    }
}

/// A label and value for the Details pane (language, speech model, audio state).
public struct NoteDetail: Sendable, Equatable {
    public var label: LocalizedStringResource
    public var value: String

    public init(label: LocalizedStringResource, value: String) {
        self.label = label
        self.value = value
    }
}

public struct NoteContent: Sendable {
    public var summary: NoteSummary
    public var layers: [NoteLayer]
    public var speakers: [NoteSpeaker]
    public var details: [NoteDetail]

    public init(
        summary: NoteSummary,
        layers: [NoteLayer] = [],
        speakers: [NoteSpeaker] = [],
        details: [NoteDetail] = []
    ) {
        self.summary = summary
        self.layers = layers
        self.speakers = speakers
        self.details = details
    }
}

/// An opaque paging position; only the source that returned it reads it.
public struct NoteCursor: Sendable, Hashable {
    public let token: String
    public init(token: String) { self.token = token }
}

public struct NotePage: Sendable {
    public var items: [NoteSummary]
    public var next: NoteCursor?
    public var total: Int

    public init(items: [NoteSummary] = [], next: NoteCursor? = nil, total: Int = 0) {
        self.items = items
        self.next = next
        self.total = total
    }
}

/// An action of the owner on a note (finish the transcript, regenerate, open Models).
public struct NoteSourceAction: Identifiable, Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let symbolName: String
    public let isDestructive: Bool
    public let perform: @Sendable () async throws -> Void

    public init(
        id: String,
        title: LocalizedStringResource,
        symbolName: String,
        isDestructive: Bool = false,
        perform: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.isDestructive = isDestructive
        self.perform = perform
    }
}

/// The recorded notes a plugin owns, read by the Notes section. A plugin keeps its data; Notes only reads it.
public protocol NoteSource: Sendable {
    var pluginID: PluginID { get }
    /// `list`, `exists` and `content` throw whenever the owner's store is not open (switched off, Keychain locked
    /// or denied, failed, not yet opened); only an open store may report absence. The error type is the source's
    /// own (a plugin cannot import Notes, so the contract names none): the consumer treats ANY thrown error as
    /// "source unavailable", never as "the note is gone", and never detaches or reports absence because of one.
    func list(matching: NormalizedQuery?, after: NoteCursor?, limit: Int) async throws -> NotePage
    /// Batch for the detach sweep: the subset of `keys` that still exist. Any thrown error means "unknown"
    /// (store not open), never "none exist".
    func exists(_ keys: [NoteKey]) async throws -> Set<NoteKey>
    /// `nil` means the note is gone (the store is open and has no such note); any thrown error means "unknown"
    /// (source off, failed, locked).
    func content(for key: NoteKey) async throws -> NoteContent?
    func delete(_ key: NoteKey) async throws
    func actions(for key: NoteKey) -> [NoteSourceAction]
    /// One stream per call (`.bufferingNewest(1)`), finished on `deactivate()`.
    func makeChanges() -> AsyncStream<Void>
}

/// Optional capability, found with `as?`: the edits that must stay in the owner.
public protocol NoteSourceEditing: NoteSource {
    func renameTitle(_ key: NoteKey, to: String) async throws
    func renameSpeaker(_ key: NoteKey, speakerID: String, to: String) async throws
    /// Marks the speaker as the user; the owner sets its notes `stale`.
    func markSelf(_ key: NoteKey, speakerID: String) async throws
}

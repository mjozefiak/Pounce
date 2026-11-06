import Darwin
import Foundation

@testable import MeetingsPlugin

/// The JSON one evaluation run writes (schema 1). The key names are a contract with `scripts/meeting-eval`:
/// do not rename them. It carries numbers and the transcript the scorer needs; the runner never prints the text.
struct EvalResult: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    struct Config: Codable, Equatable, Sendable {
        var engine: String
        var language: String
        var codeVersion: String
    }

    struct Segment: Codable, Equatable, Sendable {
        var track: String
        var startMs: Int
        var endMs: Int
        var text: String
        /// Additive and optional (schema 1 stays compatible): the speaker label of the segment, when diarized.
        var speaker: String?

        init(track: String, startMs: Int, endMs: Int, text: String, speaker: String? = nil) {
            self.track = track
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
            self.speaker = speaker
        }
    }

    struct ASR: Codable, Equatable, Sendable {
        var processingSeconds: Double
        var rtf: Double
        var peakFootprintMB: Double
        var deferredSegments: Int
        var segments: [Segment]
    }

    struct Diarization: Codable, Equatable, Sendable {
        var seconds: Double
        var peakFootprintMB: Double
        var speakers: Int
    }

    struct Notes: Codable, Equatable, Sendable {
        var model: String
        var seconds: Double
        var peakFootprintMB: Double
        var status: String
        var chunkCount: Int
        var verifiedPoints: Int
        var dropped: Int
        var failedChunks: Int
        var reduceFailed: Bool
        var markdown: String
    }

    var schema: Int = EvalResult.schemaVersion
    var recording: String
    var audioSeconds: Double
    var config: Config
    var asr: ASR
    var diarization: Diarization?
    var notes: Notes?

    private enum CodingKeys: String, CodingKey {
        case schema, recording, audioSeconds, config, asr, diarization, notes
    }

    init(
        recording: String, audioSeconds: Double, config: Config, asr: ASR, diarization: Diarization? = nil,
        notes: Notes? = nil
    ) {
        self.recording = recording
        self.audioSeconds = audioSeconds
        self.config = config
        self.asr = asr
        self.diarization = diarization
        self.notes = notes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        recording = try container.decode(String.self, forKey: .recording)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        config = try container.decode(Config.self, forKey: .config)
        asr = try container.decode(ASR.self, forKey: .asr)
        diarization = try container.decodeIfPresent(Diarization.self, forKey: .diarization)
        notes = try container.decodeIfPresent(Notes.self, forKey: .notes)
    }

    /// The optional sections are always written, as `null` when absent (the scorer reads the keys directly).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(recording, forKey: .recording)
        try container.encode(audioSeconds, forKey: .audioSeconds)
        try container.encode(config, forKey: .config)
        try container.encode(asr, forKey: .asr)
        if let diarization {
            try container.encode(diarization, forKey: .diarization)
        } else {
            try container.encodeNil(forKey: .diarization)
        }
        if let notes {
            try container.encode(notes, forKey: .notes)
        } else {
            try container.encodeNil(forKey: .notes)
        }
    }
}

/// The notes trace one run writes beside the result (`<name>.notes-trace.json`). It holds ids, counts, enums
/// and times only (see `NotesTrace`), never transcript or notes text.
struct NotesTraceFile: Codable, Equatable {
    var schema: Int = NotesTrace.schemaVersion
    var recording: String
    var events: [NotesTraceEvent]
}

enum EvalResultWriter {
    struct WriteFailure: Error { let code: Int32 }

    static func data(for result: EvalResult) throws -> Data {
        try encoded(result)
    }

    static func data(for trace: NotesTraceFile) throws -> Data {
        try encoded(trace)
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Writes `<directory>/<recording>.json` atomically (a temporary file in the same folder, created with mode
    /// 0600, then renamed over the target) and returns its URL.
    @discardableResult
    static func write(_ result: EvalResult, to directory: URL) throws -> URL {
        try writeAtomically(try data(for: result), named: "\(result.recording).json", to: directory)
    }

    /// Writes `<directory>/<recording>.notes-trace.json` the same way.
    @discardableResult
    static func write(_ trace: NotesTraceFile, to directory: URL) throws -> URL {
        try writeAtomically(try data(for: trace), named: "\(trace.recording).notes-trace.json", to: directory)
    }

    /// Writes `<directory>/<recording>.notes-rejections.json` the same way.
    @discardableResult
    static func write(_ report: NotesRejectionReport, to directory: URL) throws -> URL {
        try writeAtomically(
            try encoded(report), named: "\(report.recording).notes-rejections.json", to: directory)
    }

    private static func writeAtomically(_ body: Data, named name: String, to directory: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: name)
        let temporary = directory.appending(path: ".\(name).\(UUID().uuidString).tmp")
        guard
            manager.createFile(atPath: temporary.path, contents: body, attributes: [.posixPermissions: 0o600])
        else { throw WriteFailure(code: errno) }
        if rename(temporary.path, target.path) != 0 {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw WriteFailure(code: code)
        }
        return target
    }
}

import Foundation
import LintelCore
import LintelPersistence
import Synchronization
import os

/// Owner of `Plugins/dictation/vocabulary.json`: the user's own terms and the spoken variants they replace
/// (DICT-1.1, ADR 0010).
///
/// Format: `{"version": 1, "terms": [{"term": String, "aliases": [String]}]}` (`aliases` may be missing
/// when read, at most `maximumTerms` terms are read), written through
/// `AtomicFile` (0600). `load()` reads the file once; dictation only reads the prepared `replacer`, never
/// the disk. A file that does not decode is moved to one `vocabulary.json.corrupt` (replacing the previous
/// copy) and the vocabulary starts empty; a file with a newer `version` is read when it still has the
/// known shape, but never written or moved. Terms and aliases are never logged.
final class VocabularyStore: Sendable {
    static let fileName = "vocabulary.json"
    static let corruptFileName = "vocabulary.json.corrupt"
    static let version = 1
    /// A vocabulary holds at most this many terms; `save` refuses more.
    static let maximumTerms = 2_000

    struct Term: Codable, Equatable, Sendable {
        var term: String
        var aliases: [String]

        init(term: String, aliases: [String]) {
            self.term = term
            self.aliases = aliases
        }

        /// `aliases` may be missing in a hand-written file; it is always written.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            term = try container.decode(String.self, forKey: .term)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        }
    }

    private struct FileContents: Codable {
        var version: Int
        var terms: [Term]
    }

    private struct VersionOnly: Decodable {
        var version: Int
    }

    enum SaveError: Error, Equatable {
        /// The file comes from a newer version: it is never overwritten.
        case readOnly
        case tooManyTerms
        case write
    }

    /// Why the file is not simply there and writable, for the Vocabulary section's notice (DICT-1.2). Added with
    /// the panel: nothing about loading or saving changed.
    enum Condition: Equatable, Sendable {
        /// Read, or missing; writable.
        case normal
        /// The file did not decode, so it was moved to `vocabulary.json.corrupt` and the vocabulary started empty.
        case setAside
        /// The file comes from a newer version: it is used but never written.
        case newerVersion
        /// The file exists but could not be read: nothing is written over it.
        case unreadable
    }

    private struct State {
        var terms: [Term] = []
        var replacer = TermReplacer(entries: [])
        var isReadOnly = false
        var condition = Condition.normal
    }

    let fileURL: URL
    private let corruptURL: URL
    private let logger: Logger
    private let state = Mutex(State())
    /// Writes the encoded file; the real one is `AtomicFile`. Tests and DEBUG QA replace it to fail a save.
    private let write: @Sendable (Data, URL) throws -> Void

    init(
        directory: URL, logger: Logger = Logger(subsystem: "com.lintelapp", category: "dictation"),
        write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in try AtomicFile.write(data, to: url) }
    ) {
        fileURL = directory.appending(path: Self.fileName)
        corruptURL = directory.appending(path: Self.corruptFileName)
        self.logger = logger
        self.write = write
    }

    /// Where the damaged file's copy is (`vocabulary.json.corrupt`).
    var corruptCopyURL: URL { corruptURL }
    var condition: Condition { state.withLock { $0.condition } }

    var terms: [Term] { state.withLock { $0.terms } }
    var replacer: TermReplacer { state.withLock { $0.replacer } }
    var isReadOnly: Bool { state.withLock { $0.isReadOnly } }

    /// Reads the file. A missing file means an empty vocabulary.
    func load() {
        state.withLock { $0.condition = .normal }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            replace(terms: [], readOnly: false)
            if (error as NSError).code != NSFileReadNoSuchFileError {
                // Unreadable but present: nothing is written over it this session.
                logger.error("Cannot read vocabulary.json")
                state.withLock {
                    $0.isReadOnly = true
                    $0.condition = .unreadable
                }
            }
            return
        }
        guard let header = try? JSONDecoder().decode(VersionOnly.self, from: data), header.version >= 1 else {
            setAsideCorruptFile()
            return
        }
        let contents = try? JSONDecoder().decode(FileContents.self, from: data)
        if header.version > Self.version {
            logger.notice("vocabulary.json comes from a newer version; the vocabulary is read-only")
            replace(terms: capped(contents?.terms ?? []), readOnly: true)
            state.withLock { $0.condition = .newerVersion }
        } else if let contents {
            replace(terms: capped(contents.terms), readOnly: false)
        } else {
            setAsideCorruptFile()
        }
    }

    /// Keeps the first `maximumTerms` terms; only the count dropped is logged.
    private func capped(_ terms: [Term]) -> [Term] {
        guard terms.count > Self.maximumTerms else { return terms }
        logger.notice("vocabulary.json has \(terms.count - Self.maximumTerms) terms over the limit; they are ignored")
        return Array(terms.prefix(Self.maximumTerms))
    }

    /// Replaces the whole vocabulary and writes it.
    func save(_ terms: [Term]) throws {
        guard !isReadOnly else { throw SaveError.readOnly }
        guard terms.count <= Self.maximumTerms else { throw SaveError.tooManyTerms }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(FileContents(version: Self.version, terms: terms))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try write(data, fileURL)
        } catch {
            logger.error("Cannot write vocabulary.json")
            throw SaveError.write
        }
        replace(terms: terms, readOnly: false)
    }

    /// "Erase Data": removes the file and the corrupt copy, whatever their version.
    func erase() throws {
        for url in [fileURL, corruptURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        replace(terms: [], readOnly: false)
        state.withLock { $0.condition = .normal }
    }

    private func replace(terms: [Term], readOnly: Bool) {
        let replacer = TermReplacer(entries: terms.map { .init(term: $0.term, aliases: $0.aliases) })
        state.withLock {
            $0.terms = terms
            $0.replacer = replacer
            $0.isReadOnly = readOnly
        }
    }

    private func setAsideCorruptFile() {
        logger.error("vocabulary.json is corrupt; starting with an empty vocabulary")
        let manager = FileManager.default
        var movedAside = false
        do {
            if manager.fileExists(atPath: corruptURL.path) { try manager.removeItem(at: corruptURL) }
            try manager.moveItem(at: fileURL, to: corruptURL)
            movedAside = true
        } catch {
            logger.error("Cannot set aside vocabulary.json")
        }
        replace(terms: [], readOnly: false)
        if movedAside { state.withLock { $0.condition = .setAside } }
    }
}

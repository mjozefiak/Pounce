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

    private struct State {
        var terms: [Term] = []
        var replacer = TermReplacer(entries: [])
        var isReadOnly = false
    }

    let fileURL: URL
    private let corruptURL: URL
    private let logger: Logger
    private let state = Mutex(State())

    init(directory: URL, logger: Logger = Logger(subsystem: "com.lintelapp", category: "dictation")) {
        fileURL = directory.appending(path: Self.fileName)
        corruptURL = directory.appending(path: Self.corruptFileName)
        self.logger = logger
    }

    var terms: [Term] { state.withLock { $0.terms } }
    var replacer: TermReplacer { state.withLock { $0.replacer } }
    var isReadOnly: Bool { state.withLock { $0.isReadOnly } }

    /// Reads the file. A missing file means an empty vocabulary.
    func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            replace(terms: [], readOnly: false)
            if (error as NSError).code != NSFileReadNoSuchFileError {
                // Unreadable but present: nothing is written over it this session.
                logger.error("Cannot read vocabulary.json")
                state.withLock { $0.isReadOnly = true }
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
            try AtomicFile.write(data, to: fileURL)
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
        do {
            if manager.fileExists(atPath: corruptURL.path) { try manager.removeItem(at: corruptURL) }
            try manager.moveItem(at: fileURL, to: corruptURL)
        } catch {
            logger.error("Cannot set aside vocabulary.json")
        }
        replace(terms: [], readOnly: false)
    }
}

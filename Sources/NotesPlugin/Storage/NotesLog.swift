import CryptoKit
import Foundation
import os

/// One line of the Notes log: a stable event name, an error code, a count and a duration, and the key of the
/// note it is about, hashed. Never a title, a text, a comment or a prompt (spec "Diagnostics").
struct NotesLogEvent: Sendable, Equatable {
    var event: String
    var code: String?
    var count: Int?
    var durationMs: Int?
    var keyHash: String?

    init(_ event: String, code: String? = nil, count: Int? = nil, durationMs: Int? = nil, key: String? = nil) {
        self.event = event
        self.code = code
        self.count = count
        self.durationMs = durationMs
        self.keyHash = key.map(NotesLog.hashedKey)
    }

    var line: String {
        var parts = [event]
        if let code { parts.append("code=\(code)") }
        if let count { parts.append("count=\(count)") }
        if let durationMs { parts.append("ms=\(durationMs)") }
        if let keyHash { parts.append("key=\(keyHash)") }
        return parts.joined(separator: " ")
    }
}

/// The port the store and opener log through; tests record what reaches it.
protocol NotesLogging: Sendable {
    func log(_ event: NotesLogEvent, isError: Bool)
}

extension NotesLogging {
    func notice(_ event: NotesLogEvent) { log(event, isError: false) }
    func error(_ event: NotesLogEvent) { log(event, isError: true) }
}

enum NotesLog {
    /// A note key as it may appear in a log: the first 4 bytes of its SHA-256, in hex.
    static func hashedKey(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// The real log: `Logger(subsystem: "com.lintelapp", category: "notes")`, everything `.public` because every
/// field is a code, a count, a duration or a hash.
struct OSNotesLog: NotesLogging {
    static let subsystem = "com.lintelapp"
    static let category = "notes"

    private let logger = Logger(subsystem: subsystem, category: category)

    func log(_ event: NotesLogEvent, isError: Bool) {
        let line = event.line
        if isError {
            logger.error("\(line, privacy: .public)")
        } else {
            logger.notice("\(line, privacy: .public)")
        }
    }
}

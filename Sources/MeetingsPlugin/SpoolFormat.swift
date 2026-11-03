import CryptoKit
import Foundation

/// Which side of the call a spool file holds. The raw value is the name in `<track>.spool` and in the
/// sub-key `info`.
enum SpoolTrack: String, Sendable, CaseIterable {
    case mic
    case system

    var headerByte: UInt8 {
        switch self {
        case .mic: 0
        case .system: 1
        }
    }
}

enum SpoolError: Error, Equatable, Sendable {
    /// The file already exists. A spool file is created exclusively and never reopened for writing, because
    /// writing again would repeat a (key, nonce) pair.
    case alreadyExists
    case insufficientDiskSpace(available: Int64, required: Int64)
    case writerClosed
    /// An earlier write failed; the file ends in a partial frame and takes no more audio.
    case writerFailed
    case ioFailure(errno: Int32)
    case notASpoolFile
    case unsupportedVersion(UInt16)
    /// The header names another meeting or track than the one asked for.
    case headerMismatch
    /// A frame whose length or flags cannot be valid.
    case corruptFrame(index: UInt64)
    /// The frame is complete on disk but fails authentication: flipped byte, reordered or duplicated frame,
    /// changed header or a wrong key.
    case authenticationFailed(frameIndex: UInt64)
    case trailingData
}

/// Spool file layout (spec: Architecture, SpoolWriter / SpoolReader).
///
/// ```
/// header  = "PNCSPOOL" | version u16 | track u8 | reserved u8 | meeting uuid (16 B)        (28 bytes)
/// frame   = length u32 | flags u8 | ciphertext (length bytes) | GCM tag (16 B)
/// ```
/// All integers are big-endian. The samples are 16 kHz mono Int16, little-endian. A frame holds 2 s
/// (32 000 samples, 64 000 bytes); the last one has the "end" flag and the rest of the audio. Nonce =
/// 4 zero bytes | frame counter u64 (from 0). AAD = header | counter u64 | length u32 | flags u8. The key is
/// per file, so a (key, nonce) pair is never reused as long as a file is never reopened for writing.
enum SpoolFormat {
    static let magic = Data("PNCSPOOL".utf8)
    static let version: UInt16 = 1
    static let sampleRate = 16_000
    static let samplesPerFrame = 2 * sampleRate
    static let maxFrameBytes = samplesPerFrame * MemoryLayout<Int16>.size
    static let headerLength = 28
    static let frameHeaderLength = 5
    static let tagLength = 16
    static let finalFlag: UInt8 = 1

    /// Free space needed to start a recording: 1.5 GiB (about 700 MB of spool for 3 h plus headroom).
    static let minimumFreeBytes: Int64 = 1_610_612_736

    static func header(meeting: UUID, track: SpoolTrack) -> Data {
        var data = magic
        data.append(contentsOf: [UInt8(version >> 8), UInt8(version & 0xFF), track.headerByte, 0])
        withUnsafeBytes(of: meeting.uuid) { data.append(contentsOf: $0) }
        return data
    }

    static func nonce(frame: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: frame.bigEndian) { bytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: bytes)
    }

    static func authenticatedData(header: Data, frame: UInt64, length: UInt32, flags: UInt8) -> Data {
        var data = header
        withUnsafeBytes(of: frame.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: length.bigEndian) { data.append(contentsOf: $0) }
        data.append(flags)
        return data
    }
}

extension MeetingKeys {
    /// The key of one spool file: `master.derived(info: "spool/<meeting uuid>/<track>")`.
    func spoolKey(meeting: UUID, track: SpoolTrack) -> SymmetricKey {
        master.derived(info: "\(Self.spoolInfo)/\(SpoolStorage.name(of: meeting))/\(track.rawValue)")
    }
}

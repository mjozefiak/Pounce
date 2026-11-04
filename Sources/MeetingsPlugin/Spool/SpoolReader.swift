import CryptoKit
import Foundation
import Synchronization

/// Reads a spool track sequentially, decrypting and authenticating every frame. A truncated tail yields all
/// complete frames and then ends with `endState` `.missingEndMarker` or `.truncatedMidFrame`; a damaged,
/// reordered or duplicated frame throws. A reader opened with `requireCleanEnd` throws `endedEarly` instead of
/// ending quietly on a truncated stream. After any throw the reader is poisoned: it keeps throwing the same error.
final class SpoolReader: AudioSampleSource {
    private struct State {
        var descriptor: Int32
        var frame: UInt64 = 0
        var endState: AudioEndState?
        var failure: SpoolError?
    }

    private let header: Data
    private let key: SymmetricKey
    private let requiresCleanEnd: Bool
    private let state: Mutex<State>

    var sampleRate: Int { SpoolFormat.sampleRate }

    /// `nil` while frames remain; the end state once the stream is over.
    var endState: AudioEndState? { state.withLock { $0.endState } }

    /// - Parameter requireCleanEnd: throw `endedEarly` when the stream is truncated instead of ending with
    ///   `endState` set (the default, which crash recovery wants).
    init(file url: URL, meeting: UUID, track: SpoolTrack, keys: MeetingKeys, requireCleanEnd: Bool = false) throws {
        // O_NONBLOCK so that opening a FIFO or device cannot hang; only regular files are accepted.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw SpoolError.ioFailure(errno: errno) }
        let header: Data
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw SpoolError.ioFailure(errno: errno) }
            guard info.st_mode & S_IFMT == S_IFREG else { throw SpoolError.notASpoolFile }
            _ = fcntl(descriptor, F_SETFL, 0)
            header = try Self.read(SpoolFormat.headerLength, from: descriptor)
            guard header.count == SpoolFormat.headerLength, header.prefix(8) == SpoolFormat.magic else {
                throw SpoolError.notASpoolFile
            }
            let version = UInt16(header[8]) << 8 | UInt16(header[9])
            guard version == SpoolFormat.version else { throw SpoolError.unsupportedVersion(version) }
            guard header[10] == track.headerByte, header[SpoolFormat.uuidRange] == SpoolFormat.uuidBytes(meeting)
            else { throw SpoolError.headerMismatch }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        self.header = header
        key = keys.spoolKey(meeting: meeting, track: track, salt: Data(header[SpoolFormat.saltRange]))
        requiresCleanEnd = requireCleanEnd
        state = Mutex(State(descriptor: descriptor))
    }

    deinit {
        _ = state.withLock { Darwin.close($0.descriptor) }
    }

    /// The next frame's samples (the final frame may be empty), or `nil` at the end of the stream.
    func nextSamples() throws -> [Int16]? {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            do {
                return try step(&state)
            } catch {
                let failure = error as? SpoolError ?? .ioFailure(errno: EIO)
                state.failure = failure
                throw failure
            }
        }
    }

    private func step(_ state: inout State) throws -> [Int16]? {
        if let end = state.endState {
            if requiresCleanEnd, !end.isClean { throw SpoolError.endedEarly(end) }
            return nil
        }
        let index = state.frame
        let head = try Self.read(SpoolFormat.frameHeaderLength, from: state.descriptor)
        if head.isEmpty {
            state.endState = .missingEndMarker
            return try step(&state)
        }
        guard head.count == SpoolFormat.frameHeaderLength else {
            state.endState = .truncatedMidFrame
            return try step(&state)
        }
        let length = head.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let flags = head[4]
        guard length <= UInt32(SpoolFormat.maxFrameBytes), length % 2 == 0, flags & ~SpoolFormat.finalFlag == 0
        else {
            throw SpoolError.corruptFrame(index: index)
        }
        let body = try Self.read(Int(length) + SpoolFormat.tagLength, from: state.descriptor)
        guard body.count == Int(length) + SpoolFormat.tagLength else {
            state.endState = .truncatedMidFrame
            return try step(&state)
        }
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: SpoolFormat.nonce(frame: index), ciphertext: body.prefix(Int(length)),
                tag: body.suffix(SpoolFormat.tagLength))
            let aad = SpoolFormat.authenticatedData(header: header, frame: index, length: length, flags: flags)
            plain = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw SpoolError.authenticationFailed(frameIndex: index)
        }
        state.frame += 1
        if flags & SpoolFormat.finalFlag != 0 {
            guard try Self.read(1, from: state.descriptor).isEmpty else { throw SpoolError.trailingData }
            state.endState = .complete
        }
        return plain.withUnsafeBytes { raw in
            (0..<plain.count / 2).map {
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
            }
        }
    }

    func nextChunk() throws -> [Float]? {
        while let samples = try nextSamples() {
            if !samples.isEmpty { return samples.map { Float($0) / 32768 } }
        }
        return nil
    }

    /// Reads up to `count` bytes; fewer only at the end of the file.
    private static func read(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var total = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while total < count {
                let got = Darwin.read(descriptor, base + total, count - total)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw SpoolError.ioFailure(errno: errno)
                }
                if got == 0 { break }
                total += got
            }
        }
        return data.prefix(total)
    }
}

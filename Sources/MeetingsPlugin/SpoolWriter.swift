import CryptoKit
import Foundation
import Synchronization

/// Writes one encrypted spool track (`mic.spool` or `system.spool`). Created with `O_EXCL` and never
/// reopened: the API has no way to append to an existing file, because the frame counter would restart and
/// repeat a (key, nonce) pair. After a crash the meeting is `incomplete` and recording does not resume.
final class SpoolWriter: Sendable {
    typealias FreeSpaceProvider = @Sendable (URL) throws -> Int64

    private struct State {
        var descriptor: Int32
        var frame: UInt64 = 0
        var pending: [Int16] = []
        var closed = false
        var failed = false
    }

    let url: URL
    private let header: Data
    private let key: SymmetricKey
    private let state: Mutex<State>

    private init(url: URL, descriptor: Int32, header: Data, key: SymmetricKey) {
        self.url = url
        self.header = header
        self.key = key
        state = Mutex(State(descriptor: descriptor))
    }

    /// Creates the file. Refuses (`insufficientDiskSpace`) when the volume has less than `minimumFreeBytes`
    /// free, and with `alreadyExists` when the track was ever started.
    static func create(
        in storage: SpoolStorage, meeting: UUID, track: SpoolTrack, keys: MeetingKeys,
        minimumFreeBytes: Int64 = SpoolFormat.minimumFreeBytes,
        freeSpace: FreeSpaceProvider = { try SpoolStorage.systemFreeSpace(at: $0) }
    ) throws -> SpoolWriter {
        let available = try freeSpace(storage.root)
        guard available >= minimumFreeBytes else {
            throw SpoolError.insufficientDiskSpace(available: available, required: minimumFreeBytes)
        }
        try storage.prepare(meeting: meeting)
        let url = storage.file(for: meeting, track: track)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw errno == EEXIST ? SpoolError.alreadyExists : SpoolError.ioFailure(errno: errno)
        }
        let writer = SpoolWriter(
            url: url, descriptor: descriptor, header: SpoolFormat.header(meeting: meeting, track: track),
            key: keys.spoolKey(meeting: meeting, track: track))
        do {
            fchmod(descriptor, 0o600)
            try writer.state.withLock { state in
                try writer.writeAll(writer.header, to: &state)
                try writer.sync(&state)
            }
        } catch {
            try? writer.abandon()
            throw error
        }
        return writer
    }

    /// Adds 16 kHz mono samples. Every full 2 s of audio is sealed, written and synced before this returns.
    func append(_ samples: [Int16]) throws {
        try state.withLock { state in
            try ensureWritable(state)
            state.pending.append(contentsOf: samples)
            while state.pending.count >= SpoolFormat.samplesPerFrame {
                let chunk = Array(state.pending.prefix(SpoolFormat.samplesPerFrame))
                state.pending.removeFirst(SpoolFormat.samplesPerFrame)
                try writeFrame(chunk, final: false, state: &state)
            }
        }
    }

    /// Writes the rest as the final ("end") frame and closes the file. A second call does nothing.
    func close() throws {
        try state.withLock { state in
            if state.closed { return }
            try ensureWritable(state)
            let rest = state.pending
            state.pending = []
            try writeFrame(rest, final: true, state: &state)
            state.closed = true
            Darwin.close(state.descriptor)
            state.descriptor = -1
        }
    }

    deinit {
        // Not closed cleanly: no end frame, so the reader reports the file as truncated.
        state.withLock { state in
            if state.descriptor >= 0 { Darwin.close(state.descriptor) }
        }
    }

    private func abandon() throws {
        state.withLock { state in
            if state.descriptor >= 0 { Darwin.close(state.descriptor) }
            state.descriptor = -1
            state.closed = true
        }
        try FileManager.default.removeItem(at: url)
    }

    private func ensureWritable(_ state: State) throws {
        if state.closed { throw SpoolError.writerClosed }
        if state.failed { throw SpoolError.writerFailed }
    }

    private func writeFrame(_ samples: [Int16], final: Bool, state: inout State) throws {
        var plain = Data(capacity: samples.count * 2)
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { plain.append(contentsOf: $0) } }
        let length = UInt32(plain.count)
        let flags: UInt8 = final ? SpoolFormat.finalFlag : 0
        do {
            let aad = SpoolFormat.authenticatedData(header: header, frame: state.frame, length: length, flags: flags)
            let sealed = try AES.GCM.seal(
                plain, using: key, nonce: SpoolFormat.nonce(frame: state.frame), authenticating: aad)
            var frame = Data(capacity: SpoolFormat.frameHeaderLength + plain.count + SpoolFormat.tagLength)
            withUnsafeBytes(of: length.bigEndian) { frame.append(contentsOf: $0) }
            frame.append(flags)
            frame.append(sealed.ciphertext)
            frame.append(sealed.tag)
            try writeAll(frame, to: &state)
            try sync(&state)
            state.frame += 1
        } catch {
            state.failed = true
            throw error
        }
    }

    private func writeAll(_ data: Data, to state: inout State) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(state.descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    state.failed = true
                    throw SpoolError.ioFailure(errno: errno)
                }
                offset += written
            }
        }
    }

    private func sync(_ state: inout State) throws {
        if fsync(state.descriptor) != 0 {
            state.failed = true
            throw SpoolError.ioFailure(errno: errno)
        }
    }
}

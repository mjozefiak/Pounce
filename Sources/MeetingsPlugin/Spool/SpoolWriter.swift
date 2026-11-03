import CryptoKit
import Foundation
import Synchronization

/// Writes one encrypted spool track (`mic.spool` or `system.spool`). Created with `O_EXCL` and never
/// reopened: the API has no way to append to an existing file, because the frame counter would restart and
/// repeat a (key, nonce) pair. After a crash the meeting is `incomplete` and recording does not resume.
final class SpoolWriter: Sendable {
    typealias FreeSpaceProvider = @Sendable (URL) throws -> Int64
    /// `write(2)`; a seam so tests can make a write fail or stop half way.
    typealias WriteFunction = @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    static let systemWrite: WriteFunction = { Darwin.write($0, $1, $2) }

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
    private let rawWrite: WriteFunction

    private init(url: URL, descriptor: Int32, header: Data, key: SymmetricKey, write: @escaping WriteFunction) {
        self.url = url
        self.header = header
        self.key = key
        rawWrite = write
        state = Mutex(State(descriptor: descriptor))
    }

    /// Creates the file. Refuses (`insufficientDiskSpace`) when the volume has less than `minimumFreeBytes`
    /// free, and with `alreadyExists` when the track was ever started.
    static func create(
        in storage: SpoolStorage, meeting: UUID, track: SpoolTrack, keys: MeetingKeys,
        minimumFreeBytes: Int64 = SpoolFormat.minimumFreeBytes,
        freeSpace: FreeSpaceProvider = { try SpoolStorage.systemFreeSpace(at: $0) },
        write: @escaping WriteFunction = SpoolWriter.systemWrite
    ) throws -> SpoolWriter {
        try checkFreeSpace(in: storage, required: minimumFreeBytes, freeSpace: freeSpace)
        return try createFile(in: storage, meeting: meeting, track: track, keys: keys, write: write)
    }

    /// Creates the microphone and the system track of one meeting after one free-space check that counts both
    /// (twice `minimumFreeBytes`). If the second file cannot be created, the first is removed again.
    static func createPair(
        in storage: SpoolStorage, meeting: UUID, keys: MeetingKeys,
        minimumFreeBytes: Int64 = SpoolFormat.minimumFreeBytes,
        freeSpace: FreeSpaceProvider = { try SpoolStorage.systemFreeSpace(at: $0) },
        write: @escaping WriteFunction = SpoolWriter.systemWrite
    ) throws -> (mic: SpoolWriter, system: SpoolWriter) {
        try checkFreeSpace(in: storage, required: minimumFreeBytes * 2, freeSpace: freeSpace)
        let mic = try createFile(in: storage, meeting: meeting, track: .mic, keys: keys, write: write)
        do {
            let system = try createFile(in: storage, meeting: meeting, track: .system, keys: keys, write: write)
            return (mic, system)
        } catch {
            try? mic.abandon()
            throw error
        }
    }

    private static func checkFreeSpace(in storage: SpoolStorage, required: Int64, freeSpace: FreeSpaceProvider) throws {
        let available = try freeSpace(storage.root)
        guard available >= required else {
            throw SpoolError.insufficientDiskSpace(available: available, required: required)
        }
    }

    private static func createFile(
        in storage: SpoolStorage, meeting: UUID, track: SpoolTrack, keys: MeetingKeys,
        write: @escaping WriteFunction
    ) throws -> SpoolWriter {
        try storage.prepare(meeting: meeting)
        let url = storage.file(for: meeting, track: track)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw errno == EEXIST ? SpoolError.alreadyExists : SpoolError.ioFailure(errno: errno)
        }
        let salt = SpoolFormat.randomSalt()
        let writer = SpoolWriter(
            url: url, descriptor: descriptor, header: SpoolFormat.header(meeting: meeting, track: track, salt: salt),
            key: keys.spoolKey(meeting: meeting, track: track, salt: salt), write: write)
        do {
            fchmod(descriptor, 0o600)
            try writer.state.withLock { state in
                try writer.writeAll(writer.header, to: &state)
                try writer.sync(&state)
            }
            // The new directory entry must survive a crash too.
            try SpoolStorage.syncDirectory(url.deletingLastPathComponent())
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

    func abandon() throws {
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
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = rawWrite(state.descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    state.failed = true
                    throw SpoolError.ioFailure(errno: errno)
                }
                if written == 0 {
                    state.failed = true
                    throw SpoolError.ioFailure(errno: EIO)
                }
                offset += written
            }
        }
    }

    private func sync(_ state: inout State) throws {
        if !SpoolStorage.flush(state.descriptor) {
            state.failed = true
            throw SpoolError.ioFailure(errno: errno)
        }
    }
}

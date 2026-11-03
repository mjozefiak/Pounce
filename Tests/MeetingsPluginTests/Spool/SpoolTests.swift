import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import MeetingsPlugin

@Suite struct SpoolTests {
    let directory: TemporaryDirectory
    let storage: SpoolStorage
    let keys: MeetingKeys
    let meeting = UUID()

    init() throws {
        directory = try TemporaryDirectory()
        storage = SpoolStorage(pluginDirectory: directory.url)
        keys = try testKeys()
    }

    private func makeWriter(_ track: SpoolTrack = .mic, meeting: UUID? = nil) throws -> SpoolWriter {
        try SpoolWriter.create(
            in: storage, meeting: meeting ?? self.meeting, track: track, keys: keys,
            freeSpace: { _ in Int64.max })
    }

    private func makeReader(_ track: SpoolTrack = .mic) throws -> SpoolReader {
        try SpoolReader(file: storage.file(for: meeting, track: track), meeting: meeting, track: track, keys: keys)
    }

    /// Distinct, recognisable samples.
    private func samples(_ count: Int, offset: Int = 0) -> [Int16] {
        (0..<count).map { Int16(truncatingIfNeeded: ($0 + offset) &* 7 &+ 1000) }
    }

    private func readAll(_ reader: SpoolReader) throws -> [Int16] {
        var all: [Int16] = []
        while let chunk = try reader.nextSamples() { all += chunk }
        return all
    }

    private func write(_ audio: [Int16], track: SpoolTrack = .mic, close: Bool = true) throws {
        let writer = try makeWriter(track)
        try writer.append(audio)
        if close { try writer.close() }
    }

    private func frameOffsets(_ url: URL) throws -> [(start: Int, length: Int)] {
        let data = try Data(contentsOf: url)
        var offsets: [(Int, Int)] = []
        var position = SpoolFormat.headerLength
        while position + SpoolFormat.frameHeaderLength <= data.count {
            let length = data[position..<position + 4].reduce(0) { $0 << 8 | Int($1) }
            let total = SpoolFormat.frameHeaderLength + length + SpoolFormat.tagLength
            offsets.append((position, total))
            position += total
        }
        return offsets
    }

    @Test func roundTripAcrossFrames() throws {
        let audio = samples(32_000 * 2 + 12_345)
        try write(audio)
        let reader = try makeReader()
        #expect(try readAll(reader) == audio)
        #expect(reader.endState == .complete)
        #expect(try reader.nextSamples() == nil)
    }

    @Test func framesHoldTwoSecondsAndTheLastOneCarriesTheRest() throws {
        try write(samples(32_000 + 10))
        let offsets = try frameOffsets(storage.file(for: meeting, track: .mic))
        #expect(offsets.count == 2)
        #expect(offsets[0].length == SpoolFormat.frameHeaderLength + 64_000 + 16)
    }

    @Test func emptyRecordingIsAStillCleanFile() throws {
        try write([])
        let reader = try makeReader()
        #expect(try readAll(reader).isEmpty)
        #expect(reader.endState == .complete)
    }

    @Test func chunkStreamYieldsFloatsAndSkipsEmptyFinalFrame() throws {
        try write([16384, -16384] + samples(32_000 - 2))
        let reader = try makeReader()
        let first = try #require(try reader.nextChunk())
        #expect(first[0] == 0.5 && first[1] == -0.5)
        #expect(try reader.nextChunk() == nil)
        #expect(reader.endState == .complete)
        #expect(reader.sampleRate == 16_000)
    }

    @Test func fileCannotBeReopenedForWriting() throws {
        try write(samples(100))
        #expect(throws: SpoolError.alreadyExists) { _ = try makeWriter() }
        let again = try? makeWriter()
        #expect(again == nil)
        // The first recording is intact.
        #expect(try readAll(makeReader()).count == 100)
    }

    @Test func writeAfterCloseFails() throws {
        let writer = try makeWriter()
        try writer.close()
        try writer.close()
        #expect(throws: SpoolError.writerClosed) { try writer.append([1]) }
    }

    @Test func tamperedHeaderIsRejected() throws {
        try write(samples(500))
        let url = storage.file(for: meeting, track: .mic)
        let original = try Data(contentsOf: url)

        // Magic, version, track, uuid: refused when opening, each with its own error.
        let expected: [(index: Int, error: SpoolError)] = [
            (0, .notASpoolFile), (9, .unsupportedVersion(0)), (10, .headerMismatch), (20, .headerMismatch),
        ]
        for (index, error) in expected {
            var data = original
            data[index] ^= 0x01
            try data.write(to: url)
            #expect(throws: error) { _ = try makeReader() }
        }
        // The reserved byte and the salt are not checked on open, but both are in every frame's AAD (the salt
        // also changes the key).
        for index in [11, SpoolFormat.saltRange.lowerBound, SpoolFormat.saltRange.upperBound - 1] {
            var data = original
            data[index] ^= 0x01
            try data.write(to: url)
            let reader = try makeReader()
            #expect(throws: SpoolError.authenticationFailed(frameIndex: 0)) { _ = try reader.nextSamples() }
        }
    }

    @Test func wrongMeetingTrackOrKeyIsRejected() throws {
        try write(samples(500))
        let url = storage.file(for: meeting, track: .mic)
        #expect(throws: SpoolError.headerMismatch) {
            _ = try SpoolReader(file: url, meeting: UUID(), track: .mic, keys: keys)
        }
        #expect(throws: SpoolError.headerMismatch) {
            _ = try SpoolReader(file: url, meeting: meeting, track: .system, keys: keys)
        }
        let other = try testKeys(3)
        let reader = try SpoolReader(file: url, meeting: meeting, track: .mic, keys: other)
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 0)) { _ = try reader.nextSamples() }
    }

    @Test func notASpoolFile() throws {
        let url = directory.url.appending(path: "x.spool")
        try Data(repeating: 0x41, count: 100).write(to: url)
        #expect(throws: SpoolError.notASpoolFile) {
            _ = try SpoolReader(file: url, meeting: meeting, track: .mic, keys: keys)
        }
    }

    @Test func privacyAttributesAndModes() throws {
        try write(samples(10))
        let folder = storage.directory(for: meeting)
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let marker = folder.appending(path: ".metadata_never_index")
        #expect(FileManager.default.fileExists(atPath: marker.path))

        func mode(_ url: URL) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        #expect(try mode(folder) == 0o700)
        #expect(try mode(storage.root) == 0o700)
        #expect(try mode(storage.file(for: meeting, track: .mic)) == 0o600)
        #expect(try mode(marker) == 0o600)
    }

    private func salt(of url: URL) throws -> Data {
        Data(try Data(contentsOf: url)[SpoolFormat.saltRange])
    }

    private func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    @Test func micAndSystemUseDifferentSubkeys() throws {
        let audio = samples(1000)
        try write(audio, track: .mic)
        try write(audio, track: .system)
        let micSalt = try salt(of: storage.file(for: meeting, track: .mic))
        let systemSalt = try salt(of: storage.file(for: meeting, track: .system))
        #expect(micSalt != systemSalt)
        let mic = keys.spoolKey(meeting: meeting, track: .mic, salt: micSalt)
        let system = keys.spoolKey(meeting: meeting, track: .system, salt: systemSalt)
        #expect(bytes(mic) != bytes(system))
        #expect(bytes(mic) != bytes(keys.spoolKey(meeting: UUID(), track: .mic, salt: micSalt)))
        #expect(bytes(mic) != bytes(keys.spoolKey(meeting: meeting, track: .mic, salt: systemSalt)))
        #expect(bytes(mic) == bytes(keys.spoolKey(meeting: meeting, track: .mic, salt: micSalt)))
        let hex = micSalt.map { String(format: "%02x", $0) }.joined()
        let info = "spool/\(meeting.uuidString.lowercased())/mic/\(hex)"
        #expect(bytes(mic) == bytes(keys.master.derived(info: info)))

        // Ciphertext of identical audio differs between the tracks.
        let micFile = try Data(contentsOf: storage.file(for: meeting, track: .mic))
        let systemFile = try Data(contentsOf: storage.file(for: meeting, track: .system))
        #expect(micFile.dropFirst(SpoolFormat.headerLength) != systemFile.dropFirst(SpoolFormat.headerLength))
        #expect(try readAll(makeReader(.system)) == audio)
    }

    @Test func recreatingTheSameMeetingAndTrackGetsAnotherSaltAndKey() throws {
        let audio = samples(1000)
        try write(audio)
        let url = storage.file(for: meeting, track: .mic)
        let first = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try write(audio)
        let second = try Data(contentsOf: url)
        #expect(first[SpoolFormat.saltRange] != second[SpoolFormat.saltRange])
        // Same plaintext, same frame counter (so the same nonce), different key: the ciphertext differs.
        #expect(first.dropFirst(SpoolFormat.headerLength) != second.dropFirst(SpoolFormat.headerLength))
        let k1 = keys.spoolKey(meeting: meeting, track: .mic, salt: Data(first[SpoolFormat.saltRange]))
        let k2 = keys.spoolKey(meeting: meeting, track: .mic, salt: Data(second[SpoolFormat.saltRange]))
        #expect(bytes(k1) != bytes(k2))
        // The old content cannot be spliced under the new header.
        try (second.prefix(SpoolFormat.headerLength) + first.dropFirst(SpoolFormat.headerLength)).write(to: url)
        let reader = try makeReader()
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 0)) { _ = try reader.nextSamples() }
    }

    @Test func everyKeyAndNonceOfTheFilesOnDiskIsUnique() throws {
        // Read from the files themselves: the salt in each header gives the key, and the frames found by
        // walking the file give the counter, which is the nonce (4 zero bytes | counter u64).
        var seen = Set<Data>()
        var frames = 0
        for track in SpoolTrack.allCases {
            try write(samples(32_000 * 3 + 5), track: track)
            let url = storage.file(for: meeting, track: track)
            let data = try Data(contentsOf: url)
            let key = bytes(keys.spoolKey(meeting: meeting, track: track, salt: Data(data[SpoolFormat.saltRange])))
            let offsets = try frameOffsets(url)
            #expect(offsets.count == 4)
            for (index, frame) in offsets.enumerated() {
                var nonce = Data(count: 4)
                withUnsafeBytes(of: UInt64(index).bigEndian) { nonce.append(contentsOf: $0) }
                #expect(nonce.count == 12)
                // The frame really opens with exactly that nonce.
                let length = frame.length - SpoolFormat.frameHeaderLength - SpoolFormat.tagLength
                let body = data[frame.start + SpoolFormat.frameHeaderLength..<frame.start + frame.length]
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonce), ciphertext: body.prefix(length), tag: body.suffix(16))
                let aad = SpoolFormat.authenticatedData(
                    header: data.prefix(SpoolFormat.headerLength), frame: UInt64(index), length: UInt32(length),
                    flags: data[frame.start + 4])
                _ = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
                #expect(seen.insert(key + nonce).inserted)
                frames += 1
            }
        }
        #expect(seen.count == frames && frames == 8)
    }

    @Test func nonceIsFourZeroBytesAndABigEndianCounter() throws {
        let nonce = try SpoolFormat.nonce(frame: 0x0102)
        #expect(nonce.withUnsafeBytes { Array($0) } == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2])
    }

    @Test func flippedByteIsDetectedInEveryPartOfAFrame() throws {
        try write(samples(32_000 + 100))
        let url = storage.file(for: meeting, track: .mic)
        let original = try Data(contentsOf: url)
        let offsets = try frameOffsets(url)
        let first = offsets[0].start
        // Ciphertext and tag of frame 0 fail authentication.
        for position in [first + 5, first + 1000, first + offsets[0].length - 1] {
            var data = original
            data[position] ^= 0x80
            try data.write(to: url)
            let reader = try makeReader()
            #expect(throws: SpoolError.authenticationFailed(frameIndex: 0)) { _ = try readAll(reader) }
        }
        // A flag bit this version does not define is refused before decrypting.
        var data = original
        data[first + 4] ^= 0x80
        try data.write(to: url)
        #expect(throws: SpoolError.corruptFrame(index: 0)) { _ = try readAll(makeReader()) }
    }

    @Test func flippingTheFinalFlagIsDetected() throws {
        try write(samples(32_000 + 100))
        let url = storage.file(for: meeting, track: .mic)
        let original = try Data(contentsOf: url)
        let offsets = try frameOffsets(url)

        // The last frame loses its "end" flag: the bit is in the AAD, so this is not a quiet truncation.
        var data = original
        data[offsets[1].start + 4] ^= 0x01
        try data.write(to: url)
        let reader = try makeReader()
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 1)) { _ = try readAll(reader) }

        // A middle frame gains the flag.
        data = original
        data[offsets[0].start + 4] ^= 0x01
        try data.write(to: url)
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 0)) { _ = try readAll(makeReader()) }
    }

    @Test func impossibleLengthsAndFlagsAreCorruptFrames() throws {
        try write(samples(32_000 + 100))
        let url = storage.file(for: meeting, track: .mic)
        let original = try Data(contentsOf: url)
        let start = try frameOffsets(url)[0].start

        func patched(length: UInt32? = nil, flags: UInt8? = nil) throws -> SpoolReader {
            var data = original
            if let length {
                data.replaceSubrange(start..<start + 4, with: withUnsafeBytes(of: length.bigEndian) { Data($0) })
            }
            if let flags { data[start + 4] = flags }
            try data.write(to: url)
            return try makeReader()
        }
        let oversize = UInt32(SpoolFormat.maxFrameBytes + 2)
        for reader in [try patched(length: oversize), try patched(length: UInt32.max)] {
            #expect(throws: SpoolError.corruptFrame(index: 0)) { _ = try reader.nextSamples() }
        }
        #expect(throws: SpoolError.corruptFrame(index: 0)) { _ = try patched(length: 63_999).nextSamples() }
        #expect(throws: SpoolError.corruptFrame(index: 0)) { _ = try patched(flags: 0x02).nextSamples() }
        #expect(throws: SpoolError.corruptFrame(index: 0)) { _ = try patched(flags: 0xFF).nextSamples() }
    }

    @Test func aReaderThatThrewKeepsThrowing() throws {
        try write(samples(32_000 * 2 + 100))
        let url = storage.file(for: meeting, track: .mic)
        var data = try Data(contentsOf: url)
        let offsets = try frameOffsets(url)
        data[offsets[1].start + 10] ^= 0x01
        try data.write(to: url)
        let reader = try makeReader()
        #expect(try reader.nextSamples()?.count == 32_000)
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 1)) { _ = try reader.nextSamples() }
        // Not a quiet end, and not the next frame either.
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 1)) { _ = try reader.nextSamples() }
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 1)) { _ = try reader.nextChunk() }
    }

    @Test func swappedAndDuplicatedFramesAreDetected() throws {
        try write(samples(32_000 * 2 + 100))
        let url = storage.file(for: meeting, track: .mic)
        let original = try Data(contentsOf: url)
        let offsets = try frameOffsets(url)
        func slice(_ index: Int) -> Data {
            original[offsets[index].start..<offsets[index].start + offsets[index].length]
        }
        let header = original.prefix(SpoolFormat.headerLength)

        try (header + slice(1) + slice(0) + slice(2)).write(to: url)
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 0)) { _ = try readAll(makeReader()) }

        try (header + slice(0) + slice(0) + slice(1) + slice(2)).write(to: url)
        let reader = try makeReader()
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 1)) { _ = try readAll(reader) }

        // Dropping a middle frame is caught too.
        try (header + slice(0) + slice(2)).write(to: url)
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 1)) { _ = try readAll(makeReader()) }
    }

    @Test func dataAfterTheEndFrameIsRejected() throws {
        try write(samples(100))
        let url = storage.file(for: meeting, track: .mic)
        var data = try Data(contentsOf: url)
        data.append(0)
        try data.write(to: url)
        #expect(throws: SpoolError.trailingData) { _ = try readAll(makeReader()) }
    }

    @Test func missingEndFrameIsDistinguishedFromTruncationMidFrame() throws {
        let audio = samples(32_000 * 2 + 50)
        // Not closed: two complete frames, no end marker. (Dropping the writer without close is a crash.)
        do {
            let writer = try makeWriter()
            try writer.append(audio)
        }
        let url = storage.file(for: meeting, track: .mic)
        let reader = try makeReader()
        #expect(try readAll(reader) == Array(audio.prefix(64_000)))
        #expect(reader.endState == .missingEndMarker)
        #expect(reader.endState?.isClean == false)

        // Cut inside the second frame.
        let data = try Data(contentsOf: url)
        let offsets = try frameOffsets(url)
        for cut in [offsets[1].start + 3, offsets[1].start + 100, data.count - 1] {
            try data.prefix(cut).write(to: url)
            let truncated = try makeReader()
            #expect(try readAll(truncated) == Array(audio.prefix(32_000)))
            #expect(truncated.endState == .truncatedMidFrame)
        }
    }

    @Test func cleanFileLosingItsLastBytesIsTruncated() throws {
        let audio = samples(32_000 + 500)
        try write(audio)
        let url = storage.file(for: meeting, track: .mic)
        let data = try Data(contentsOf: url)
        try data.dropLast(10).write(to: url)
        let reader = try makeReader()
        #expect(try readAll(reader) == Array(audio.prefix(32_000)))
        #expect(reader.endState == .truncatedMidFrame)
    }

    @Test func refusesToStartWithLittleFreeSpace() throws {
        #expect(SpoolFormat.minimumFreeBytes == 1_610_612_736)
        let enough = SpoolFormat.minimumFreeBytes
        #expect(throws: SpoolError.insufficientDiskSpace(available: enough - 1, required: enough)) {
            _ = try SpoolWriter.create(
                in: storage, meeting: meeting, track: .mic, keys: keys, freeSpace: { _ in enough - 1 })
        }
        #expect(!FileManager.default.fileExists(atPath: storage.directory(for: meeting).path))
        let writer = try SpoolWriter.create(
            in: storage, meeting: meeting, track: .mic, keys: keys, freeSpace: { _ in enough })
        try writer.close()
    }

    @Test func customThresholdIsHonoured() throws {
        #expect(throws: SpoolError.insufficientDiskSpace(available: 10, required: 11)) {
            _ = try SpoolWriter.create(
                in: storage, meeting: meeting, track: .mic, keys: keys, minimumFreeBytes: 11, freeSpace: { _ in 10 })
        }
    }

    @Test func systemFreeSpaceProviderReadsTheVolume() throws {
        #expect(try SpoolStorage.systemFreeSpace(at: storage.root) > 0)
    }

    @Test func fileHoldsNoPlaintextAudio() throws {
        // A loud, recognisable pattern: 0x1234 0x5678 repeated.
        let pattern: [Int16] = [0x1234, 0x5678, 0x1234, 0x5678, 0x1234, 0x5678, 0x1234, 0x5678]
        let audio = Array((0..<10_000).map { _ in pattern }.joined())
        try write(audio)
        let data = try Data(contentsOf: storage.file(for: meeting, track: .mic))
        let needle = Data([0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0x78, 0x56])
        #expect(data.range(of: needle) == nil)
        #expect(data.range(of: Data([0x12, 0x34, 0x56, 0x78])) == nil)
        // Sanity: the scan would find it in plaintext, and the file is not much bigger than the audio.
        var plain = Data()
        for sample in audio { withUnsafeBytes(of: sample.littleEndian) { plain.append(contentsOf: $0) } }
        #expect(plain.range(of: needle) != nil)
        #expect(data.count < plain.count + 200)
        // Nothing else on disk holds audio: only the spool file and the marker.
        let names = try FileManager.default.contentsOfDirectory(atPath: storage.directory(for: meeting).path)
        #expect(Set(names) == ["mic.spool", ".metadata_never_index"])
    }

    // MARK: Truncation

    @Test func truncationIsSurfacedThroughTheSampleSourceProtocol() throws {
        let writer = try makeWriter()
        try writer.append(samples(32_000 + 50))
        let source: any AudioSampleSource = try makeReader()
        #expect(source.endState == nil)
        var total = 0
        while let chunk = try source.nextChunk() { total += chunk.count }
        #expect(total == 32_000)
        #expect(source.endState == .missingEndMarker)
        #expect(throws: SpoolError.endedEarly(.missingEndMarker)) { try source.requireCleanEnd() }
    }

    @Test func aCleanStreamPassesRequireCleanEnd() throws {
        try write(samples(500))
        let source: any AudioSampleSource = try makeReader()
        while try source.nextChunk() != nil {}
        try source.requireCleanEnd()
    }

    @Test func aStrictReaderThrowsInsteadOfEndingQuietly() throws {
        let writer = try makeWriter()
        try writer.append(samples(32_000 + 50))
        let url = storage.file(for: meeting, track: .mic)
        let reader = try SpoolReader(file: url, meeting: meeting, track: .mic, keys: keys, requireCleanEnd: true)
        #expect(try reader.nextSamples()?.count == 32_000)
        #expect(throws: SpoolError.endedEarly(.missingEndMarker)) { _ = try reader.nextSamples() }
        #expect(throws: SpoolError.endedEarly(.missingEndMarker)) { _ = try reader.nextChunk() }

        try write(samples(10), track: .system)
        let clean = try SpoolReader(
            file: storage.file(for: meeting, track: .system), meeting: meeting, track: .system, keys: keys,
            requireCleanEnd: true)
        #expect(try readAll(clean).count == 10)
    }

    // MARK: Crashes, failures and hostile files

    @Test func creatingAgainAfterACrashIsRefusedAndKeepsTheOldAudio() throws {
        let audio = samples(32_000 + 7)
        do {
            let crashed = try makeWriter()
            try crashed.append(audio)
        }
        #expect(throws: SpoolError.alreadyExists) { _ = try makeWriter() }
        let reader = try makeReader()
        #expect(try readAll(reader) == Array(audio.prefix(32_000)))
        #expect(reader.endState == .missingEndMarker)
    }

    @Test func aFailedWriteMakesTheWriterRefuseEverythingAndWritesNoFinalFrame() throws {
        let calls = Mutex(0)
        let flaky: SpoolWriter.WriteFunction = { descriptor, pointer, count in
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            // 1: header, 2: frame 0, 3: half of frame 1, 4 and later: the disk fails.
            if call == 3 { return Darwin.write(descriptor, pointer, count / 2) }
            if call >= 4 {
                errno = EIO
                return -1
            }
            return Darwin.write(descriptor, pointer, count)
        }
        let writer = try SpoolWriter.create(
            in: storage, meeting: meeting, track: .mic, keys: keys, freeSpace: { _ in .max }, write: flaky)
        #expect(throws: SpoolError.self) { try writer.append(samples(32_000 * 2)) }
        #expect(throws: SpoolError.writerFailed) { try writer.append([1]) }
        #expect(throws: SpoolError.writerFailed) { try writer.close() }

        let reader = try makeReader()
        #expect(try readAll(reader).count == 32_000)
        #expect(reader.endState == .truncatedMidFrame)
        #expect(reader.endState?.isClean == false)
    }

    @Test func aSymbolicLinkAtTheSpoolPathIsNeverFollowed() throws {
        let target = directory.url.appending(path: "target")
        try Data("untouched".utf8).write(to: target)
        try storage.prepare(meeting: meeting)
        let url = storage.file(for: meeting, track: .mic)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        #expect(throws: SpoolError.alreadyExists) { _ = try makeWriter() }
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))
        #expect(throws: SpoolError.ioFailure(errno: ELOOP)) { _ = try makeReader() }
    }

    @Test func aSymbolicLinkInPlaceOfTheMeetingFolderIsRefused() throws {
        let outside = directory.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: storage.directory(for: meeting), withDestinationURL: outside)
        #expect(throws: SpoolError.ioFailure(errno: ELOOP)) { _ = try makeWriter() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func aFifoIsNotASpoolFileAndDoesNotBlockTheReader() throws {
        let url = directory.url.appending(path: "pipe.spool")
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(throws: SpoolError.notASpoolFile) {
            _ = try SpoolReader(file: url, meeting: meeting, track: .mic, keys: keys)
        }
    }

    @Test func anExistingSpoolRootGetsMode0700() throws {
        try FileManager.default.createDirectory(
            at: storage.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try write(samples(10))
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: storage.root.path)[.posixPermissions] as? Int)
        #expect(mode == 0o700)
    }

    @Test func bothTracksNeedTwiceTheFreeSpace() throws {
        let each: Int64 = 1_000
        #expect(throws: SpoolError.insufficientDiskSpace(available: 1_999, required: 2_000)) {
            _ = try SpoolWriter.createPair(
                in: storage, meeting: meeting, keys: keys, minimumFreeBytes: each, freeSpace: { _ in 1_999 })
        }
        #expect(!FileManager.default.fileExists(atPath: storage.directory(for: meeting).path))
        let pair = try SpoolWriter.createPair(
            in: storage, meeting: meeting, keys: keys, minimumFreeBytes: each, freeSpace: { _ in 2_000 })
        try pair.mic.close()
        try pair.system.close()
        #expect(try readAll(makeReader(.mic)).isEmpty)
        #expect(try readAll(makeReader(.system)).isEmpty)
    }

    @Test func aFailedSecondTrackLeavesNoFirstTrackBehind() throws {
        try storage.prepare(meeting: meeting)
        try Data().write(to: storage.file(for: meeting, track: .system))
        #expect(throws: SpoolError.alreadyExists) {
            _ = try SpoolWriter.createPair(in: storage, meeting: meeting, keys: keys, freeSpace: { _ in .max })
        }
        #expect(!FileManager.default.fileExists(atPath: storage.file(for: meeting, track: .mic).path))
    }

    // MARK: Maintenance

    @Test func removeSpoolsForMeetings() throws {
        let other = UUID()
        try write(samples(10))
        _ = try SpoolWriter.create(in: storage, meeting: other, track: .mic, keys: keys, freeSpace: { _ in .max })
        let removed = storage.removeSpools(forMeetings: [
            meeting.uuidString, UUID().uuidString, "../escape", "not-a-uuid",
        ])
        #expect(removed == [meeting.uuidString])
        #expect(!FileManager.default.fileExists(atPath: storage.directory(for: meeting).path))
        #expect(FileManager.default.fileExists(atPath: storage.directory(for: other).path))
    }

    @Test func removeSpoolsOlderThanTheCutoffOnlyAmongTheCandidates() throws {
        let old = UUID()
        let recent = UUID()
        let activeButOld = UUID()
        for id in [old, recent, activeButOld] {
            _ = try SpoolWriter.create(in: storage, meeting: id, track: .mic, keys: keys, freeSpace: { _ in .max })
        }
        let past = Date(timeIntervalSinceNow: -10 * 86_400)
        for id in [old, activeButOld] {
            for item in [
                storage.directory(for: id),
                storage.file(for: id, track: .mic),
                storage.directory(for: id).appending(path: ".metadata_never_index"),
            ] {
                try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: item.path)
            }
        }
        // A stranger in the root is never touched.
        let stranger = storage.root.appending(path: "keep-me")
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: stranger.path)

        let candidates: Set<String> = [old.uuidString, recent.uuidString, "not-a-uuid"]
        #expect(
            storage.removeSpools(olderThan: Date(timeIntervalSinceNow: -7 * 86_400), among: candidates) == [
                old.uuidString
            ])
        #expect(!FileManager.default.fileExists(atPath: storage.directory(for: old).path))
        #expect(FileManager.default.fileExists(atPath: storage.directory(for: recent).path))
        // Old, but not a candidate (a meeting still being recorded or processed): untouched.
        #expect(FileManager.default.fileExists(atPath: storage.directory(for: activeButOld).path))
        #expect(FileManager.default.fileExists(atPath: stranger.path))
    }

    @Test func aSymbolicLinkedMeetingFolderIsNeverFollowedOrRemoved() throws {
        let outside = directory.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appending(path: "file"))
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        let link = storage.directory(for: meeting)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(storage.removeSpools(forMeetings: [meeting.uuidString]).isEmpty)
        #expect(storage.removeSpools(olderThan: .distantFuture, among: [meeting.uuidString]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "file").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func maintenanceOnMissingRootDoesNothing() {
        #expect(storage.removeSpools(olderThan: .now, among: [UUID().uuidString]).isEmpty)
        #expect(storage.removeSpools(forMeetings: [UUID().uuidString]).isEmpty)
    }
}

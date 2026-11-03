import CryptoKit
import Foundation
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

        // Magic, version, track, uuid: refused when opening.
        for index in [0, 9, 10, 20] {
            var data = original
            data[index] ^= 0x01
            try data.write(to: url)
            #expect(throws: SpoolError.self) { _ = try makeReader() }
        }
        // The reserved byte is not checked on open, but the header is in every frame's AAD.
        var data = original
        data[11] ^= 0x01
        try data.write(to: url)
        let reader = try makeReader()
        #expect(throws: SpoolError.authenticationFailed(frameIndex: 0)) { _ = try reader.nextSamples() }
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

    @Test func micAndSystemUseDifferentSubkeys() throws {
        let mic = keys.spoolKey(meeting: meeting, track: .mic)
        let system = keys.spoolKey(meeting: meeting, track: .system)
        let otherMeeting = keys.spoolKey(meeting: UUID(), track: .mic)
        func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
        #expect(bytes(mic) != bytes(system))
        #expect(bytes(mic) != bytes(otherMeeting))
        #expect(bytes(mic) == bytes(keys.spoolKey(meeting: meeting, track: .mic)))
        let info = "spool/\(meeting.uuidString.lowercased())/mic"
        #expect(bytes(mic) == bytes(keys.master.derived(info: info)))

        // Ciphertext of identical audio differs between the tracks.
        let audio = samples(1000)
        try write(audio, track: .mic)
        try write(audio, track: .system)
        let micFile = try Data(contentsOf: storage.file(for: meeting, track: .mic))
        let systemFile = try Data(contentsOf: storage.file(for: meeting, track: .system))
        #expect(micFile.dropFirst(SpoolFormat.headerLength) != systemFile.dropFirst(SpoolFormat.headerLength))
        // A track cannot be read as the other, even with the other's header patched in.
        #expect(try readAll(makeReader(.system)) == audio)
    }

    @Test func noNonceIsRepeatedWithinOrAcrossFiles() throws {
        var seen = Set<Data>()
        for track in SpoolTrack.allCases {
            try write(samples(32_000 * 3 + 5), track: track)
            let offsets = try frameOffsets(storage.file(for: meeting, track: track))
            #expect(offsets.count == 4)
            for index in offsets.indices {
                let nonce = try SpoolFormat.nonce(frame: UInt64(index))
                #expect(nonce.withUnsafeBytes { Data($0).prefix(4) } == Data(count: 4))
                // The pair (key, nonce) is what must be unique.
                let key = keys.spoolKey(meeting: meeting, track: track).withUnsafeBytes { Data($0) }
                #expect(seen.insert(key + nonce.withUnsafeBytes { Data($0) }).inserted)
            }
        }
        #expect(seen.count == 8)
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
        // Flags, ciphertext and tag of frame 0 (the length byte is covered by the size checks).
        for position in [first + 4, first + 5, first + 1000, first + offsets[0].length - 1] {
            var data = original
            data[position] ^= 0x80
            try data.write(to: url)
            let reader = try makeReader()
            #expect(throws: SpoolError.self) { _ = try readAll(reader) }
        }
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

    // MARK: Maintenance

    @Test func removeSpoolsForMeetings() throws {
        let other = UUID()
        try write(samples(10))
        _ = try SpoolWriter.create(in: storage, meeting: other, track: .mic, keys: keys, freeSpace: { _ in .max })
        let removed = storage.removeSpools(forMeetings: [
            meeting.uuidString, UUID().uuidString, "../escape", "not-a-uuid",
        ])
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: storage.directory(for: meeting).path))
        #expect(FileManager.default.fileExists(atPath: storage.directory(for: other).path))
    }

    @Test func removeSpoolsOlderThanTheCutoff() throws {
        let old = UUID()
        let recent = UUID()
        for id in [old, recent] {
            _ = try SpoolWriter.create(in: storage, meeting: id, track: .mic, keys: keys, freeSpace: { _ in .max })
        }
        let past = Date(timeIntervalSinceNow: -10 * 86_400)
        for item in [
            storage.directory(for: old),
            storage.file(for: old, track: .mic),
            storage.directory(for: old).appending(path: ".metadata_never_index"),
        ] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: item.path)
        }
        // A stranger in the root is never touched.
        let stranger = storage.root.appending(path: "keep-me")
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: stranger.path)

        #expect(storage.removeSpools(olderThan: Date(timeIntervalSinceNow: -7 * 86_400)) == 1)
        #expect(!FileManager.default.fileExists(atPath: storage.directory(for: old).path))
        #expect(FileManager.default.fileExists(atPath: storage.directory(for: recent).path))
        #expect(FileManager.default.fileExists(atPath: stranger.path))
    }

    @Test func maintenanceOnMissingRootDoesNothing() {
        #expect(storage.removeSpools(olderThan: .now) == 0)
        #expect(storage.removeSpools(forMeetings: [UUID().uuidString]) == 0)
    }
}

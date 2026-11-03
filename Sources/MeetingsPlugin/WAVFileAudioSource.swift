import Foundation
import PounceSpeech

enum WAVError: Error, Equatable {
    case notWAV
    case unsupported(String)
}

/// Samples of a 16 kHz mono WAV (16-bit PCM or 32-bit float), read into memory. Used by tests and by the
/// DEBUG `--qa…` options as a stand-in for the microphone or the system track. Nothing is written anywhere.
enum WAVFile {
    static func samples(from data: Data) throws -> [Float] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8)
        else { throw WAVError.notWAV }
        var format: (tag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = Int(le32(bytes, offset + 4))
            let body = offset + 8
            if id == "fmt ", body + 16 <= bytes.count {
                format = (le16(bytes, body), le16(bytes, body + 2), le32(bytes, body + 4), le16(bytes, body + 14))
            } else if id == "data" {
                guard let format else { throw WAVError.notWAV }
                guard format.channels == 1, format.rate == UInt32(AudioFormat.sampleRate) else {
                    throw WAVError.unsupported("need 16 kHz mono, got \(format.rate) Hz x \(format.channels)")
                }
                let end = min(body + size, bytes.count)
                return try decode(bytes[body..<end], tag: format.tag, bits: format.bits)
            }
            offset = body + size + (size & 1)
        }
        throw WAVError.notWAV
    }

    private static func decode(_ body: ArraySlice<UInt8>, tag: UInt16, bits: UInt16) throws -> [Float] {
        let array = Array(body)
        switch (tag, bits) {
        case (1, 16):
            return (0..<array.count / 2).map { Float(Int16(bitPattern: le16(array, $0 * 2))) / 32_768 }
        case (3, 32):
            return (0..<array.count / 4).map { Float(bitPattern: le32(array, $0 * 4)) }
        default:
            throw WAVError.unsupported("format \(tag), \(bits) bits")
        }
    }

    private static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

/// An `AudioInput` that plays a WAV file back as chunks (as fast as the consumer reads).
final class WAVFileAudioSource: AudioInput, Sendable {
    private let samples: [Float]
    private let chunkSamples: Int

    init(data: Data, chunkSamples: Int = AudioFormat.sampleRate / 10) throws {
        samples = try WAVFile.samples(from: data)
        self.chunkSamples = max(1, chunkSamples)
    }

    convenience init(url: URL, chunkSamples: Int = AudioFormat.sampleRate / 10) throws {
        try self.init(data: Data(contentsOf: url), chunkSamples: chunkSamples)
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        var index = 0
        while index < samples.count {
            let chunk = Array(samples[index..<min(index + chunkSamples, samples.count)])
            onLevel(MicrophoneCapture.level(of: chunk))
            continuation.yield(chunk)
            index += chunkSamples
        }
        continuation.finish()
        return stream
    }

    func stop() async {}
}

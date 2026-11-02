import AVFoundation
import CoreAudio
import Foundation
import os

/// The microphone permission, read without a prompt and asked for only on request.
struct SystemMicrophoneAuthorizer: MicrophoneAuthorizer {
    func status() -> MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

enum CaptureError: Error {
    case noInputDevice
    case converterUnavailable
    case engineFailed(String)
}

/// `AVAudioEngine` on the chosen input (or the system's), converted to 16 kHz mono `Float32` and handed out
/// in memory; nothing is written to disk. The stream ends when the device goes away or the Mac sleeps.
final class MicrophoneCapture: AudioInput, @unchecked Sendable {
    private let deviceUID: String?
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var continuation: AsyncStream<[Float]>.Continuation?

    /// - Parameter deviceUID: the input device's UID from Settings, or `nil` for the system's input.
    init(deviceUID: String? = nil) {
        self.deviceUID = deviceUID
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws -> AsyncStream<[Float]> {
        let engine = AVAudioEngine()
        if let deviceUID {
            try Self.select(deviceUID: deviceUID, on: engine)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioFormat.sampleRate), channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: format, to: target)
        else { throw CaptureError.converterUnavailable }

        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let ratio = target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            onLevel(Self.level(of: samples))
            continuation.yield(samples)
        }
        // A device change or sleep reconfigures the engine and stops it: end the stream.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.finishStream()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NotificationCenter.default.removeObserver(observer)
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        lock.withLock {
            self.engine = engine
            self.observer = observer
            self.continuation = continuation
        }
        return stream
    }

    func stop() async {
        let (engine, observer, continuation) = lock.withLock {
            () -> (AVAudioEngine?, (any NSObjectProtocol)?, AsyncStream<[Float]>.Continuation?) in
            defer {
                self.engine = nil
                self.observer = nil
                self.continuation = nil
            }
            return (self.engine, self.observer, self.continuation)
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        continuation?.finish()
    }

    private func finishStream() {
        let continuation = lock.withLock { self.continuation }
        continuation?.finish()
    }

    /// A 0...1 loudness for the HUD from the RMS, on a log scale so quiet speech still moves it.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let decibels = 10 * log10(max(meanSquare, 1e-9))
        return min(1, max(0, (decibels + 60) / 60))
    }

    // MARK: Input devices

    struct InputDevice: Identifiable, Equatable, Sendable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// Every device that can record.
    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                let name = string(kAudioObjectPropertyName, of: id)
            else { return nil }
            return InputDevice(uid: uid, name: name)
        }
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func string(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size,
                &device)
        }
        return status == noErr && device != 0 ? device : nil
    }

    private static func select(deviceUID: String, on engine: AVAudioEngine) throws {
        guard let device = deviceID(forUID: deviceUID), let unit = engine.inputNode.audioUnit else {
            throw CaptureError.noInputDevice
        }
        var id = device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.noInputDevice }
    }
}

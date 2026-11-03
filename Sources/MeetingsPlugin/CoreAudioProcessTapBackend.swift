import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// The real Core Audio side of `SystemAudioSource`: `CATapDescription` + `AudioHardwareCreateProcessTap`, a
/// private aggregate device around the default output and the tap, and an IO proc. Compiled and driven by
/// hand only (`docs/qa.md`, "Meetings audio sources"); no test creates a tap, because that would show the
/// consent prompt and capture real audio. Never logs audio.
struct CoreAudioProcessTapBackend: ProcessTapBackend {
    func startTap(
        excludingOwnProcess: Bool, onBuffer: @escaping @Sendable (TapBuffer) -> Void
    ) throws(SystemAudioError) -> any ProcessTapSession {
        let session = CoreAudioTapSession()
        do {
            try session.open(excludingOwnProcess: excludingOwnProcess, onBuffer: onBuffer)
        } catch {
            session.stop()
            throw error
        }
        return session
    }

    func observeOutputDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> any OutputChangeObservation {
        let observation = DefaultOutputObservation(handler: handler)
        observation.install()
        return observation
    }
}

private func objectAddress(
    _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// One tap with its aggregate device and IO proc. `stop()` releases all of it, in reverse order of creation.
private final class CoreAudioTapSession: ProcessTapSession, @unchecked Sendable {
    private struct Handles {
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var started = false
    }

    private let handles = Mutex(Handles())
    private let queue = DispatchQueue(label: "app.pounce.meetings.system-audio", qos: .userInteractive)

    deinit { stop() }

    func open(excludingOwnProcess: Bool, onBuffer: @escaping @Sendable (TapBuffer) -> Void) throws(SystemAudioError) {
        let excluded = excludingOwnProcess ? Self.ownProcessObject().map { [$0] } ?? [] : []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Pounce meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw SystemAudioError.tapUnavailable(tapStatus) }
        handles.withLock { $0.tap = tap }

        guard let outputUID = Self.defaultOutputUID() else { throw SystemAudioError.tapUnavailable(-1) }
        let aggregateUID = UUID().uuidString
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pounce meeting tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregate)
        guard aggregateStatus == noErr else { throw SystemAudioError.tapUnavailable(aggregateStatus) }
        handles.withLock { $0.aggregate = aggregate }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = objectAddress(kAudioTapPropertyFormat)
        let formatStatus = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format)
        guard formatStatus == noErr else { throw SystemAudioError.tapUnavailable(formatStatus) }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mChannelsPerFrame > 0, format.mSampleRate > 0
        else { throw SystemAudioError.unsupportedFormat }

        let channels = Int(format.mChannelsPerFrame)
        let rate = format.mSampleRate
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) {
            _, inputData, inputTime, _, _ in
            let samples = Self.interleave(inputData, channels: channels, nonInterleaved: nonInterleaved)
            guard !samples.isEmpty else { return }
            onBuffer(
                TapBuffer(
                    samples: samples, channels: channels, sampleRate: rate, hostTime: inputTime.pointee.mHostTime))
        }
        guard procStatus == noErr, let procID else { throw SystemAudioError.tapUnavailable(procStatus) }
        handles.withLock { $0.procID = procID }

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else { throw SystemAudioError.tapUnavailable(startStatus) }
        handles.withLock { $0.started = true }
    }

    func stop() {
        let taken = handles.withLock { handles -> Handles in
            defer { handles = Handles() }
            return handles
        }
        if taken.started, let procID = taken.procID { AudioDeviceStop(taken.aggregate, procID) }
        if let procID = taken.procID { AudioDeviceDestroyIOProcID(taken.aggregate, procID) }
        if taken.aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(taken.aggregate) }
        if taken.tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(taken.tap) }
    }

    /// Frames as interleaved samples, whatever the buffer layout.
    private static func interleave(
        _ list: UnsafePointer<AudioBufferList>, channels: Int, nonInterleaved: Bool
    ) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        if !nonInterleaved {
            guard let first = buffers.first, let data = first.mData else { return [] }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        guard buffers.count >= channels, let first = buffers.first else { return [] }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        var output = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frames { output[frame * channels + channel] = data[frame] }
        }
        return output
    }

    /// Pounce's own audio process object, or `nil` when it has not used audio yet (the tap then also hears
    /// Pounce, which plays nothing during a meeting).
    private static func ownProcessObject() -> AudioObjectID? {
        var address = objectAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputUID() -> String? {
        var address = objectAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != kAudioObjectUnknown
        else { return nil }
        var uidAddress = objectAddress(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else {
            return nil
        }
        return uid.takeRetainedValue() as String
    }
}

private final class DefaultOutputObservation: OutputChangeObservation, @unchecked Sendable {
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.pounce.meetings.output-change")
    nonisolated(unsafe) private var installed: AudioObjectPropertyListenerBlock?
    private let lock = NSLock()

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    deinit { cancel() }

    func install() {
        let handler = self.handler
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var address = objectAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        if status == noErr { lock.withLock { installed = block } }
    }

    func cancel() {
        let taken = lock.withLock { () -> AudioObjectPropertyListenerBlock? in
            defer { installed = nil }
            return installed
        }
        guard let block = taken else { return }
        var address = objectAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }
}

/// The self-test's signal: a short sine through `AVAudioEngine` on the default output.
struct AVAudioEngineTonePlayer: TonePlayer {
    var frequency: Double = 880
    var amplitude: Float = 0.25

    func play(duration: TimeInterval) async throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = engine.outputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, let buffer = tone(format: format, duration: duration) else {
            throw SystemAudioError.unsupportedFormat
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }
        await player.scheduleBuffer(buffer)
        player.play()
        try await Task.sleep(for: .seconds(duration + 0.1))
    }

    private func tone(format: AVAudioFormat, duration: TimeInterval) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate))
            for channel in 0..<Int(format.channelCount) { channels[channel][frame] = value }
        }
        return buffer
    }
}

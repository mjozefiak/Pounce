import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// The real Core Audio side of `SystemAudioSource`: `CATapDescription` + `AudioHardwareCreateProcessTap`, a
/// private aggregate device around the default output and the tap, and an IO proc. Compiled and driven by
/// hand only (`docs/qa.md`, "Meetings audio sources"); no test creates a tap, because that would show the
/// consent prompt and capture real audio. Never logs audio.
///
/// The IO callback only copies raw frames into a preallocated `TapRing` and pokes a worker queue; conversion
/// and the pipeline run on that queue, so the callback never allocates, takes a lock or logs.
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

    func observeOutputDeviceChanges(
        _ handler: @escaping @Sendable () -> Void
    ) throws(SystemAudioError) -> any OutputChangeObservation {
        let observation = DefaultOutputObservation(handler: handler)
        try observation.install()
        return observation
    }
}

private func objectAddress(
    _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// A property listener block on one audio object, removed again by `remove()` or on deinit.
private final class PropertyListener: @unchecked Sendable {
    private let object: AudioObjectID
    private let selector: AudioObjectPropertySelector
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void
    private let lock = NSLock()
    nonisolated(unsafe) private var installed: AudioObjectPropertyListenerBlock?

    init(
        object: AudioObjectID, selector: AudioObjectPropertySelector, queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        self.object = object
        self.selector = selector
        self.queue = queue
        self.handler = handler
    }

    deinit { remove() }

    /// The `OSStatus` of installing the listener.
    func install() -> OSStatus {
        let handler = self.handler
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var address = objectAddress(selector)
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status == noErr { lock.withLock { installed = block } }
        return status
    }

    func remove() {
        let taken = lock.withLock { () -> AudioObjectPropertyListenerBlock? in
            defer { installed = nil }
            return installed
        }
        guard let block = taken else { return }
        var address = objectAddress(selector)
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

/// The tap's current format, read by the IO callback without a lock and rewritten by the format listeners
/// (a Bluetooth headset switching between A2DP and HFP changes the rate on the same device).
private final class LiveFormat: Sendable {
    private let rateBits = Atomic<UInt64>(0)
    private let channelCount = Atomic<Int>(0)
    private let planar = Atomic<Bool>(false)

    var sampleRate: Double { Double(bitPattern: rateBits.load(ordering: .relaxed)) }
    /// Zero while the tap's format is unusable; the callback then drops buffers.
    var channels: Int { channelCount.load(ordering: .relaxed) }
    var nonInterleaved: Bool { planar.load(ordering: .relaxed) }

    func store(_ format: AudioStreamBasicDescription?) {
        guard let format else {
            channelCount.store(0, ordering: .relaxed)
            return
        }
        rateBits.store(format.mSampleRate.bitPattern, ordering: .relaxed)
        planar.store(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0, ordering: .relaxed)
        channelCount.store(Int(format.mChannelsPerFrame), ordering: .relaxed)
    }
}

/// One tap with its aggregate device and IO proc. `stop()` releases all of it, in reverse order of creation.
private final class CoreAudioTapSession: ProcessTapSession, @unchecked Sendable {
    private struct Handles {
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var started = false
        var worker: DispatchSourceUserDataAdd?
        var listeners: [PropertyListener] = []
    }

    private let handles = Mutex(Handles())
    private let queue = DispatchQueue(label: "app.pounce.meetings.system-audio", qos: .userInteractive)
    private let workerQueue = DispatchQueue(label: "app.pounce.meetings.system-audio.worker", qos: .userInitiated)

    deinit { stop() }

    func open(excludingOwnProcess: Bool, onBuffer: @escaping @Sendable (TapBuffer) -> Void) throws(SystemAudioError) {
        // The output device first: without one there is nothing to tap, and creating the tap would show
        // the consent prompt for nothing.
        guard let outputUID = Self.defaultOutputUID() else { throw SystemAudioError.tapUnavailable(-1) }

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

        let live = LiveFormat()
        var formatStatus: OSStatus = noErr
        guard let format = Self.tapFormat(tap, status: &formatStatus) else {
            throw formatStatus == noErr ? SystemAudioError.unsupportedFormat : .tapUnavailable(formatStatus)
        }
        live.store(format)

        // Worker: the IO callback only copies frames into the ring and pokes this source.
        let ring = TapRing()
        let worker = DispatchSource.makeUserDataAddSource(queue: workerQueue)
        worker.setEventHandler {
            while let buffer = ring.pop() { onBuffer(buffer) }
        }
        worker.resume()
        handles.withLock { $0.worker = worker }

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) {
            _, inputData, inputTime, _, _ in
            Self.enqueue(inputData, inputTime, live: live, ring: ring, worker: worker)
        }
        guard procStatus == noErr, let procID else { throw SystemAudioError.tapUnavailable(procStatus) }
        handles.withLock { $0.procID = procID }

        // A format or rate change on the tap or the device is picked up by the next callback.
        let tapObject = tap
        let refresh: @Sendable () -> Void = {
            var status: OSStatus = noErr
            live.store(Self.tapFormat(tapObject, status: &status))
        }
        let listeners = [
            PropertyListener(object: tap, selector: kAudioTapPropertyFormat, queue: workerQueue, handler: refresh),
            PropertyListener(
                object: aggregate, selector: kAudioDevicePropertyNominalSampleRate, queue: workerQueue,
                handler: refresh),
        ]
        // A listener that cannot be installed leaves the format fixed at what the tap reported at the start.
        for listener in listeners { _ = listener.install() }
        handles.withLock { $0.listeners = listeners }

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else { throw SystemAudioError.tapUnavailable(startStatus) }
        handles.withLock { $0.started = true }
    }

    func stop() {
        let taken = handles.withLock { handles -> Handles in
            defer { handles = Handles() }
            return handles
        }
        for listener in taken.listeners { listener.remove() }
        if taken.started, let procID = taken.procID { AudioDeviceStop(taken.aggregate, procID) }
        if let procID = taken.procID { AudioDeviceDestroyIOProcID(taken.aggregate, procID) }
        taken.worker?.cancel()
        if taken.aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(taken.aggregate) }
        if taken.tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(taken.tap) }
    }

    /// Audio-thread work: pick the tap's stream, copy its frames into a free ring slot, poke the worker.
    /// No allocation, lock, logging or `await`.
    private static func enqueue(
        _ inputData: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>, live: LiveFormat,
        ring: TapRing, worker: DispatchSourceUserDataAdd
    ) {
        let channels = live.channels
        let rate = live.sampleRate
        guard channels > 0, rate > 0 else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard
            let selection = TapLayout.select(
                count: list.count, tapChannels: channels, nonInterleaved: live.nonInterleaved,
                buffer: { (Int(list[$0].mNumberChannels), Int(list[$0].mDataByteSize)) })
        else {
            ring.noteDrop()
            return
        }
        let count = selection.frames * channels
        guard count <= ring.slotCapacity, let slot = ring.reserve(), let destination = slot.baseAddress else {
            ring.noteDrop()
            return
        }
        if selection.bufferCount == 1 {
            guard let source = list[selection.firstBuffer].mData else {
                ring.noteDrop()
                return
            }
            memcpy(destination, source, count * MemoryLayout<Float>.size)
        } else {
            for channel in 0..<channels {
                guard let source = list[selection.firstBuffer + channel].mData?.assumingMemoryBound(to: Float.self)
                else {
                    ring.noteDrop()
                    return
                }
                for frame in 0..<selection.frames { destination[frame * channels + channel] = source[frame] }
            }
        }
        ring.commit(
            count: count, channels: channels, sampleRate: rate, hostTime: inputTime.pointee.mHostTime,
            hostTimeValid: inputTime.pointee.mFlags.contains(.hostTimeValid))
        worker.add(data: 1)
    }

    /// The tap's format when it is float PCM, else `nil` (with `status` set when the call itself failed).
    private static func tapFormat(_ tap: AudioObjectID, status: inout OSStatus) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = objectAddress(kAudioTapPropertyFormat)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr, format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mChannelsPerFrame > 0, format.mSampleRate > 0
        else { return nil }
        return format
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
    private let listener: PropertyListener

    init(handler: @escaping @Sendable () -> Void) {
        listener = PropertyListener(
            object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice,
            queue: DispatchQueue(label: "app.pounce.meetings.output-change"), handler: handler)
    }

    func install() throws(SystemAudioError) {
        let status = listener.install()
        guard status == noErr else { throw SystemAudioError.tapUnavailable(status) }
    }

    func cancel() { listener.remove() }
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
        // Start the player first and schedule without waiting: the async `scheduleBuffer` returns only after
        // the buffer has played, which never happens on a player that is not running. The wait is the sleep,
        // so this can never hang (the self-test bounds it further).
        player.play()
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in }
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

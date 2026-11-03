import CoreAudio
import Foundation
import Synchronization

/// The real `ProcessAudioObserver`: the Core Audio process objects (macOS 14.2+), event-driven through
/// property listeners, no polling. It reads three properties and nothing else: whether a process uses an
/// input (`kAudioProcessPropertyIsRunningInput`), its bundle ID (`kAudioProcessPropertyBundleID`) and its pid
/// (`kAudioProcessPropertyPID`, only to leave Pounce's own process out). It never opens a device, creates a
/// tap or captures audio, so it shows no permission prompt.
///
/// Compiled but never run by tests (the API needs real processes). Whether the properties are available and
/// reliable on a given Mac, Bluetooth headsets included, is unverified: when the process list cannot be read,
/// or processes exist but none answers the input property, the install fails with `.unavailable`; when no
/// process ever answers (`hasAnswered`) the detector reports that it cannot confirm detection. Either way
/// suggestions only stay quiet (`docs/qa.md`, "Meetings detection"). Nothing here blocks the main actor.
struct CoreAudioProcessObserver: ProcessAudioObserver {
    func start() throws(ProcessAudioError) -> ProcessAudioSubscription {
        let (events, continuation) = AsyncStream.makeStream(
            of: ProcessAudioEvent.self, bufferingPolicy: .unbounded)
        let observation = ProcessObservation(continuation: continuation)
        // Installing reads the process list and every process's properties: that happens on the
        // observation's queue, never on the caller (the main actor).
        let install = Task.detached { await observation.install() }
        return ProcessAudioSubscription(
            events: events,
            stop: {
                observation.stop()
                continuation.finish()
            },
            installed: {
                let failure = await install.value
                if failure != nil { continuation.finish() }
                return failure
            },
            hasAnswered: { observation.hasAnswered })
    }
}

private func address(
    _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// A property listener on one audio object, delivered on the observation's queue.
private final class ObjectListener: @unchecked Sendable {
    private let object: AudioObjectID
    private let selector: AudioObjectPropertySelector
    private let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    init(object: AudioObjectID, selector: AudioObjectPropertySelector, queue: DispatchQueue) {
        self.object = object
        self.selector = selector
        self.queue = queue
    }

    /// The `OSStatus` of installing it.
    func install(_ handler: @escaping () -> Void) -> OSStatus {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var address = address(selector)
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status == noErr { self.block = block }
        return status
    }

    func remove() {
        guard let block else { return }
        self.block = nil
        var address = address(selector)
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

/// All state lives on `queue` (listener blocks arrive there too). `install()` and `stop()` hop onto it
/// asynchronously: nothing here blocks the caller, and nothing waits on the queue from the queue (the last
/// reference may drop inside a listener block).
private final class ProcessObservation: @unchecked Sendable {
    private struct Watched {
        var listener: ObjectListener
        var bundleID: String?
        var isRunningInput: Bool
    }

    private let queue = DispatchQueue(label: "app.pounce.meetings.process-audio", qos: .utility)
    private let continuation: AsyncStream<ProcessAudioEvent>.Continuation
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var listListener: ObjectListener?
    private var watched: [AudioObjectID: Watched] = [:]
    private var stopped = false
    private let stopRequested = Mutex(false)
    private let answered = Mutex(false)

    init(continuation: AsyncStream<ProcessAudioEvent>.Continuation) {
        self.continuation = continuation
    }

    /// `stop()` removes the listeners; this only covers an observation dropped without it, and never waits.
    deinit {
        var leftover = watched.values.map(\.listener)
        if let listListener { leftover.append(listListener) }
        guard !leftover.isEmpty else { return }
        let listeners = leftover
        queue.async { for listener in listeners { listener.remove() } }
    }

    /// Whether any process has ever answered the input property.
    var hasAnswered: Bool { answered.withLock { $0 } }

    func install() async -> ProcessAudioError? {
        let failure: Int32? = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.installOnQueue()) }
        }
        guard let failure else { return nil }
        queue.async { self.removeAll() }
        return .unavailable(failure)
    }

    private func installOnQueue() -> Int32? {
        guard !stopped, !stopRequested.withLock({ $0 }) else { return nil }
        let listener = ObjectListener(
            object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList,
            queue: queue)
        let status = listener.install { [weak self] in self?.refresh() }
        guard status == noErr else { return status }
        listListener = listener
        guard let objects = Self.processObjects() else { return Int32(kAudioHardwareUnknownPropertyError) }
        refresh(objects)
        // Processes exist but none answers the input property: the API is not usable here. (An empty list is
        // not a failure; the detector reports "cannot confirm" when nothing ever answers.)
        if !objects.isEmpty, watched.isEmpty, !objects.contains(where: { Self.isOwn($0, pid: ownPID) }) {
            return Int32(kAudioHardwareUnknownPropertyError)
        }
        return nil
    }

    /// Returns at once: no further event is delivered, and the listeners are removed on the queue.
    func stop() {
        stopRequested.withLock { $0 = true }
        queue.async { self.removeAll() }
    }

    private func removeAll() {
        stopped = true
        listListener?.remove()
        listListener = nil
        for entry in watched.values { entry.listener.remove() }
        watched = [:]
    }

    // MARK: Queue

    private func refresh() {
        guard !stopped, let objects = Self.processObjects() else { return }
        refresh(objects)
    }

    private func refresh(_ objects: [AudioObjectID]) {
        let current = Set(objects)
        for (object, entry) in watched where !current.contains(object) {
            entry.listener.remove()
            watched[object] = nil
            if entry.isRunningInput {
                continuation.yield(
                    ProcessAudioEvent(processObjectID: object, bundleID: entry.bundleID, isRunningInput: false))
            }
        }
        for object in objects where watched[object] == nil {
            guard !Self.isOwn(object, pid: ownPID), let running = Self.isRunningInput(object) else { continue }
            answered.withLock { $0 = true }
            let listener = ObjectListener(object: object, selector: kAudioProcessPropertyIsRunningInput, queue: queue)
            guard listener.install({ [weak self] in self?.inputChanged(object) }) == noErr else { continue }
            let bundleID = Self.bundleID(object)
            watched[object] = Watched(listener: listener, bundleID: bundleID, isRunningInput: running)
            if running {
                continuation.yield(
                    ProcessAudioEvent(processObjectID: object, bundleID: bundleID, isRunningInput: true))
            }
        }
    }

    private func inputChanged(_ object: AudioObjectID) {
        guard !stopped, var entry = watched[object], let running = Self.isRunningInput(object),
            running != entry.isRunningInput
        else { return }
        if running { entry.bundleID = Self.bundleID(object) }
        entry.isRunningInput = running
        watched[object] = entry
        continuation.yield(
            ProcessAudioEvent(processObjectID: object, bundleID: entry.bundleID, isRunningInput: running))
    }

    // MARK: Reads

    private static func processObjects() -> [AudioObjectID]? {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !objects.isEmpty else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let status = objects.withUnsafeMutableBytes { buffer in
            buffer.baseAddress.map { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0) }
                ?? OSStatus(kAudioHardwareUnspecifiedError)
        }
        guard status == noErr else { return nil }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func isRunningInput(_ object: AudioObjectID) -> Bool? {
        uint32(object, kAudioProcessPropertyIsRunningInput).map { $0 != 0 }
    }

    private static func isOwn(_ object: AudioObjectID, pid: pid_t) -> Bool {
        uint32(object, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) == pid } ?? false
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name, CFStringGetLength(name) > 0 else { return nil }
        return name as String
    }
}

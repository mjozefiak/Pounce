import Synchronization

/// A single-producer, single-consumer ring of preallocated sample slots. The Core Audio IO callback is the
/// producer: it copies the raw frames into a slot without allocating, locking or logging. A worker queue is
/// the consumer and turns slots into `TapBuffer`s, where resampling and the pipeline run. When the consumer
/// falls behind, the producer drops buffers (counted) instead of blocking the audio thread. No Core Audio.
final class TapRing: @unchecked Sendable {
    private struct Meta {
        var count = 0
        var channels = 1
        var sampleRate = 0.0
        var hostTime: UInt64 = 0
        var hostTimeValid = true
    }

    let slotCount: Int
    /// Samples (not frames) one slot holds.
    let slotCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let meta: UnsafeMutablePointer<Meta>
    /// Next slot to write (owned by the producer) and next slot to read (owned by the consumer).
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let droppedBuffers = Atomic<Int>(0)

    init(slotCount: Int = 16, slotCapacity: Int = 32_768) {
        self.slotCount = max(1, slotCount)
        self.slotCapacity = max(1, slotCapacity)
        storage = .allocate(capacity: self.slotCount * self.slotCapacity)
        storage.initialize(repeating: 0, count: self.slotCount * self.slotCapacity)
        meta = .allocate(capacity: self.slotCount)
        meta.initialize(repeating: Meta(), count: self.slotCount)
    }

    deinit {
        storage.deallocate()
        meta.deallocate()
    }

    /// Buffers dropped because the ring was full or a buffer did not fit a slot.
    var dropped: Int { droppedBuffers.load(ordering: .relaxed) }

    // MARK: Producer

    /// The memory of the next free slot, or `nil` (counted as a drop) when the ring is full.
    func reserve() -> UnsafeMutableBufferPointer<Float>? {
        let writeIndex = head.load(ordering: .relaxed)
        let readIndex = tail.load(ordering: .acquiring)
        guard writeIndex - readIndex < slotCount else {
            noteDrop()
            return nil
        }
        return UnsafeMutableBufferPointer(start: storage + (writeIndex % slotCount) * slotCapacity, count: slotCapacity)
    }

    /// Publishes the slot returned by the last `reserve()` with `count` samples in it.
    func commit(count: Int, channels: Int, sampleRate: Double, hostTime: UInt64, hostTimeValid: Bool) {
        let writeIndex = head.load(ordering: .relaxed)
        meta[writeIndex % slotCount] = Meta(
            count: min(max(0, count), slotCapacity), channels: channels, sampleRate: sampleRate, hostTime: hostTime,
            hostTimeValid: hostTimeValid)
        head.store(writeIndex + 1, ordering: .releasing)
    }

    func noteDrop() {
        droppedBuffers.add(1, ordering: .relaxed)
    }

    // MARK: Consumer

    /// The oldest published buffer, or `nil` when there is none.
    func pop() -> TapBuffer? {
        let readIndex = tail.load(ordering: .relaxed)
        let writeIndex = head.load(ordering: .acquiring)
        guard readIndex < writeIndex else { return nil }
        let slot = readIndex % slotCount
        let info = meta[slot]
        let samples = Array(UnsafeBufferPointer(start: storage + slot * slotCapacity, count: info.count))
        tail.store(readIndex + 1, ordering: .releasing)
        return TapBuffer(
            samples: samples, channels: info.channels, sampleRate: info.sampleRate, hostTime: info.hostTime,
            hostTimeValid: info.hostTimeValid)
    }
}

/// Which of the IO proc's buffers carry the tap's stream. The aggregate device lists the input streams of its
/// sub-devices first and the tap's stream last, so the tap is matched by its channel layout, searching from
/// the end, never assumed to be `buffers.first`.
enum TapLayout {
    struct Selection: Equatable {
        /// Index of the first buffer of the tap's stream.
        var firstBuffer: Int
        /// One interleaved buffer, or one per channel when non-interleaved.
        var bufferCount: Int
        /// Frames that every selected buffer holds.
        var frames: Int
    }

    /// - Parameters:
    ///   - count: number of buffers in the list.
    ///   - buffer: channels per buffer and byte size of buffer `index`.
    static func select(
        count: Int, tapChannels: Int, nonInterleaved: Bool, buffer: (Int) -> (channels: Int, bytes: Int)
    ) -> Selection? {
        guard count > 0, tapChannels > 0 else { return nil }
        let sampleSize = MemoryLayout<Float>.size
        if nonInterleaved && tapChannels > 1 {
            // One mono buffer per channel, the last `tapChannels` buffers; the shortest sets the frame count.
            guard count >= tapChannels else { return nil }
            let first = count - tapChannels
            var frames = Int.max
            for index in first..<count {
                let info = buffer(index)
                guard info.channels == 1 else { return nil }
                frames = min(frames, max(0, info.bytes) / sampleSize)
            }
            return frames > 0 ? Selection(firstBuffer: first, bufferCount: tapChannels, frames: frames) : nil
        }
        var index = count - 1
        while index >= 0 {
            let info = buffer(index)
            if info.channels == tapChannels {
                let frames = max(0, info.bytes) / (sampleSize * tapChannels)
                return frames > 0 ? Selection(firstBuffer: index, bufferCount: 1, frames: frames) : nil
            }
            index -= 1
        }
        return nil
    }
}

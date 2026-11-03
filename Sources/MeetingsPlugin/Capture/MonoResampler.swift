import Foundation

/// Converts interleaved multi-channel `Float32` audio of any sample rate to mono at a target rate. The
/// channels are averaged and the rate is changed by area averaging (a box filter, so downsampling does not
/// alias into the speech band). Stateful: feed consecutive buffers of one stream; no allocation beyond the
/// output. Pure, no Core Audio.
struct MonoResampler: Sendable {
    let inputRate: Double
    let outputRate: Double
    let channels: Int

    /// Mono input not yet consumed.
    private var pending: [Float] = []
    /// Where the next output interval starts, in input samples from `pending[0]`.
    private var position: Double = 0

    init(inputRate: Double, outputRate: Double = 16_000, channels: Int) {
        self.inputRate = max(1, inputRate)
        self.outputRate = max(1, outputRate)
        self.channels = max(1, channels)
    }

    /// Input samples per output sample.
    private var ratio: Double { inputRate / outputRate }

    /// Consumes `interleaved` (frames * channels samples) and returns the output samples that are complete.
    mutating func process(interleaved: [Float]) -> [Float] {
        let frames = interleaved.count / channels
        guard frames > 0 else { return [] }
        if channels == 1 {
            pending.append(contentsOf: interleaved.prefix(frames))
        } else {
            let scale = 1 / Float(channels)
            pending.reserveCapacity(pending.count + frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += interleaved[frame * channels + channel] }
                pending.append(sum * scale)
            }
        }
        return drain()
    }

    private mutating func drain() -> [Float] {
        let step = ratio
        var output: [Float] = []
        output.reserveCapacity(Int(Double(pending.count) / step) + 1)
        while position + step <= Double(pending.count) + 1e-9 {
            let end = min(position + step, Double(pending.count))
            output.append(Float(average(from: position, to: end)))
            position += step
        }
        // Drop what no later interval needs.
        let consumed = min(Int(position), pending.count)
        if consumed > 0 {
            pending.removeFirst(consumed)
            position -= Double(consumed)
        }
        return output
    }

    /// The mean of the input over `[start, end)`, with fractional weights at both ends.
    private func average(from start: Double, to end: Double) -> Double {
        let width = end - start
        guard width > 0 else { return 0 }
        var sum = 0.0
        var cell = Int(start)
        while Double(cell) < end, cell < pending.count {
            let lower = max(start, Double(cell))
            let upper = min(end, Double(cell + 1))
            sum += Double(pending[cell]) * (upper - lower)
            cell += 1
        }
        return sum / width
    }
}

import Foundation
import LintelKit
import Testing

@testable import MeetingsPlugin

@Suite struct ResamplerTests {
    @Test func downsamplesAStereoSineTo16kHzMono() {
        var resampler = MonoResampler(inputRate: 48_000, channels: 2)
        let input = Synth.sine(frequency: 440, rate: 48_000, frames: 48_000)
        let output = resampler.process(interleaved: input)
        #expect(abs(output.count - 16_000) <= 2)
        // 440 Hz for one second: 880 zero crossings, amplitude 0.5 -> rms 0.354 (the box filter costs < 1 %).
        #expect(abs(Synth.zeroCrossings(output) - 880) <= 3)
        #expect(abs(Synth.rms(output) - 0.3535) < 0.01)
    }

    @Test func chunkingTheInputDoesNotChangeTheOutput() {
        let input = Synth.sine(frequency: 300, rate: 44_100, frames: 44_100, channels: 1)
        var whole = MonoResampler(inputRate: 44_100, channels: 1)
        let expected = whole.process(interleaved: input)
        var parts = MonoResampler(inputRate: 44_100, channels: 1)
        var joined: [Float] = []
        var index = 0
        while index < input.count {
            joined += parts.process(interleaved: Array(input[index..<min(index + 1_237, input.count)]))
            index += 1_237
        }
        #expect(joined.count == expected.count)
        let worst = zip(joined, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-4)
    }

    @Test func aSixteenKilohertzMonoStreamPassesThrough() {
        var resampler = MonoResampler(inputRate: 16_000, channels: 1)
        let input = Synth.sine(frequency: 200, rate: 16_000, frames: 1_600, channels: 1)
        let output = resampler.process(interleaved: input)
        #expect(output.count == input.count)
        #expect(zip(output, input).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    @Test func channelsAreAveraged() {
        var resampler = MonoResampler(inputRate: 16_000, channels: 2)
        let output = resampler.process(interleaved: [1, 0, 1, 0, 1, 0, 1, 0])
        #expect(output == [0.5, 0.5, 0.5, 0.5])
    }

    @Test func upsamplesLowRates() {
        var resampler = MonoResampler(inputRate: 8_000, channels: 1)
        let output = resampler.process(interleaved: Synth.sine(frequency: 100, rate: 8_000, frames: 800, channels: 1))
        #expect(abs(output.count - 1_600) <= 2)
    }
}

@Suite struct TimelineTests {
    @Test func convertsTicksUsingTheTimebase() {
        let converter = HostTimeConverter(numer: 125, denom: 3)
        #expect(converter.nanoseconds(3_000) == 125_000)
        #expect(HostTimeConverter.identity.nanoseconds(42) == 42)
        // Large uptimes do not overflow.
        #expect(HostTimeConverter(numer: 125, denom: 3).nanoseconds(UInt64.max / 100) > 0)
    }

    @Test func hugeTickCountsSaturateInsteadOfTrapping() {
        // numer 125 / denom 3 with UInt64.max ticks: the quotient needs more than 64 bits.
        #expect(HostTimeConverter(numer: 125, denom: 3).nanoseconds(UInt64.max) == UInt64.max)
        #expect(HostTimeConverter.identity.nanoseconds(UInt64.max) == UInt64.max)
        #expect(HostTimeConverter(numer: UInt64.max, denom: 1).nanoseconds(UInt64.max) == UInt64.max)
        // The boundary: high word equal to the denominator would overflow the quotient.
        #expect(HostTimeConverter(numer: 2, denom: 2).nanoseconds(UInt64.max) == UInt64.max)
        #expect(HostTimeConverter(numer: UInt64.max, denom: UInt64.max).nanoseconds(UInt64.max) == UInt64.max)
        #expect(HostTimeConverter(numer: 0, denom: 7).nanoseconds(UInt64.max) == 0)
    }

    @Test func aHugeStampAgainstAnAlignmentDoesNotTrap() {
        let alignment = TimelineAlignment(originHostTime: 0, converter: HostTimeConverter(numer: 125, denom: 3))
        #expect(alignment.milliseconds(forHostTime: UInt64.max) > 0)
        #expect(alignment.sampleOffset(forHostTime: UInt64.max, sampleRate: 16_000) > 0)
        let late = TimelineAlignment(originHostTime: UInt64.max, converter: HostTimeConverter(numer: 125, denom: 3))
        #expect(late.milliseconds(forHostTime: 0) < 0)
    }

    @Test func tracksAlignToTheEarliestStart() throws {
        let micStart: UInt64 = 5_000_000_000
        let systemStart: UInt64 = 5_250_000_000
        let alignment = try #require(TimelineAlignment(commonStartOf: [systemStart, micStart], converter: .identity))
        #expect(alignment.originHostTime == micStart)
        #expect(alignment.milliseconds(forHostTime: micStart) == 0)
        #expect(alignment.milliseconds(forHostTime: systemStart) == 250)
        #expect(alignment.milliseconds(forHostTime: micStart + 1_500_000_000) == 1_500)
        // The later track needs 250 ms of leading silence: 4000 samples at 16 kHz.
        #expect(alignment.sampleOffset(forHostTime: systemStart, sampleRate: 16_000) == 4_000)
        #expect(alignment.sampleOffset(forHostTime: micStart, sampleRate: 16_000) == 0)
    }

    @Test func aStampBeforeTheOriginIsNegative() {
        let alignment = TimelineAlignment(originHostTime: 2_000_000_000, converter: .identity)
        #expect(alignment.milliseconds(forHostTime: 1_000_000_000) == -1_000)
        #expect(alignment.sampleOffset(forHostTime: 1_000_000_000, sampleRate: 16_000) == 0)
    }

    @Test func noTracksMeansNoAlignment() {
        #expect(TimelineAlignment(commonStartOf: [], converter: .identity) == nil)
    }
}

@Suite struct PipelineTests {
    private func buffer(frames: Int, at hostTimeMs: UInt64, startFrame: Int = 0) -> TapBuffer {
        TapBuffer(
            samples: Synth.sine(frequency: 440, rate: 48_000, frames: frames, startFrame: startFrame),
            channels: 2, sampleRate: 48_000, hostTime: hostTimeMs * 1_000_000)
    }

    @Test func contiguousBuffersProduceNoSilence() {
        var pipeline = SystemAudioPipeline(converter: .identity)
        var all = pipeline.ingest(buffer(frames: 4_800, at: 1_000))  // 100 ms
        all += pipeline.ingest(buffer(frames: 4_800, at: 1_100, startFrame: 4_800))
        all += pipeline.ingest(buffer(frames: 4_800, at: 1_200, startFrame: 9_600))
        #expect(abs(all.count - 4_800) <= 3)
        #expect(Synth.rms(all) > 0.3)
    }

    @Test func aMissingStretchBecomesSilence() {
        var pipeline = SystemAudioPipeline(converter: .identity)
        let first = pipeline.ingest(buffer(frames: 4_800, at: 1_000))  // 0..100 ms
        // The next buffer starts at 600 ms: 500 ms (8000 samples) are missing.
        let second = pipeline.ingest(buffer(frames: 4_800, at: 1_600))
        let silent = second.prefix(while: { $0 == 0 }).count
        #expect(abs(silent - 8_000) <= 3)
        #expect(abs(pipeline.emittedSamples - 11_200) <= 3)
        #expect(first.count + second.count == pipeline.emittedSamples)
    }

    @Test func jitterIsNotAGap() {
        var pipeline = SystemAudioPipeline(converter: .identity)
        _ = pipeline.ingest(buffer(frames: 4_800, at: 1_000))
        // 5 ms late: inside the tolerance.
        let second = pipeline.ingest(buffer(frames: 4_800, at: 1_105))
        #expect(abs(second.count - 1_600) <= 3)
    }

    @Test func theFirstBufferStartsTheTimelineUnlessAnAnchorIsGiven() {
        var floating = SystemAudioPipeline(converter: .identity)
        let out = floating.ingest(buffer(frames: 4_800, at: 1_000))
        #expect(floating.anchorHostTime == 1_000_000_000)
        #expect(abs(out.count - 1_600) <= 3)
        #expect(Synth.rms(out) > 0.3)
        #expect(floating.emittedSamples == out.count)

        // Capture asked at 1000 ms, first audio at 1250 ms: 250 ms of leading silence.
        var anchored = SystemAudioPipeline(converter: .identity, anchorHostTime: 1_000_000_000)
        let late = anchored.ingest(buffer(frames: 4_800, at: 1_250))
        #expect(late.prefix(while: { $0 == 0 }).count >= 3_990)
    }

    @Test func paddingFillsUpToTheGivenTime() {
        var pipeline = SystemAudioPipeline(converter: .identity)
        _ = pipeline.ingest(buffer(frames: 4_800, at: 1_000))
        let silence = pipeline.padding(upTo: 2_000_000_000)  // 1 s after the anchor
        #expect(abs(pipeline.emittedSamples - 16_000) <= 3)
        #expect(silence.allSatisfy { $0 == 0 })
        #expect(pipeline.padding(upTo: 1_500_000_000).isEmpty)
    }

    @Test func aZeroOrStaleStampDoesNotDropTheFollowingBuffers() {
        var pipeline = SystemAudioPipeline(converter: .identity)
        var all = pipeline.ingest(buffer(frames: 4_800, at: 1_000))
        for index in 1...4 {
            // The stamp is stuck at 0 (or stale): the buffers follow each other instead of being dropped.
            all += pipeline.ingest(
                TapBuffer(
                    samples: Synth.sine(frequency: 440, rate: 48_000, frames: 4_800, startFrame: index * 4_800),
                    channels: 2, sampleRate: 48_000, hostTime: 0))
        }
        #expect(abs(all.count - 8_000) <= 8)  // five 100 ms buffers
        #expect(Synth.rms(all) > 0.3)
        #expect(pipeline.resyncs == 0)
    }

    @Test func aHugeFutureStampIsCappedAndTheTimelineRebased() {
        var pipeline = SystemAudioPipeline(converter: .identity)
        _ = pipeline.ingest(buffer(frames: 4_800, at: 1_000))
        // A stamp one hour ahead: at most five seconds of silence, never an hour.
        let jump = pipeline.ingest(buffer(frames: 4_800, at: 1_000 + 3_600_000, startFrame: 4_800))
        #expect(jump.count <= SystemAudioPipeline.maxGapSamples + 1_700)
        #expect(jump.prefix(while: { $0 == 0 }).count == SystemAudioPipeline.maxGapSamples)
        #expect(pipeline.resyncs == 1)
        // The next buffer is contiguous with the new timeline, not another capped gap.
        let next = pipeline.ingest(buffer(frames: 4_800, at: 1_000 + 3_600_100, startFrame: 9_600))
        #expect(abs(next.count - 1_600) <= 3)
        #expect(pipeline.resyncs == 1)
        // And a stamp near UInt64.max neither traps nor allocates without bound.
        let extreme = pipeline.ingest(
            TapBuffer(
                samples: Synth.sine(frequency: 440, rate: 48_000, frames: 4_800), channels: 2, sampleRate: 48_000,
                hostTime: UInt64.max))
        #expect(extreme.count <= SystemAudioPipeline.maxGapSamples + 1_700)
    }

    @Test func aStampFarBehindTheOutputIsRebasedNotDropped() {
        var pipeline = SystemAudioPipeline(converter: .identity)
        _ = pipeline.ingest(buffer(frames: 4_800, at: 1_000))
        // The tap stayed down and the timeline was padded ten seconds ahead; then a buffer arrives whose
        // advancing stamp is still far behind that.
        _ = pipeline.padding(upTo: 11_000_000_000)
        let before = pipeline.emittedSamples
        let late = pipeline.ingest(buffer(frames: 4_800, at: 1_100, startFrame: 4_800))
        #expect(abs(late.count - 1_600) <= 3)
        #expect(pipeline.emittedSamples == before + late.count)
        #expect(pipeline.resyncs == 1)
    }

    @Test func aFormatChangeAfterAGapFillsTheGapAndIsCounted() {
        var pipeline = SystemAudioPipeline(converter: .identity)
        _ = pipeline.ingest(buffer(frames: 4_800, at: 1_000))
        #expect(pipeline.formatChanges == 0)
        // Bluetooth A2DP -> HFP: 48 kHz stereo to 16 kHz mono, 400 ms later than contiguous.
        let hfp = TapBuffer(
            samples: Synth.sine(frequency: 440, rate: 16_000, frames: 1_600, channels: 1), channels: 1,
            sampleRate: 16_000, hostTime: 1_500_000_000)
        let out = pipeline.ingest(hfp)
        #expect(pipeline.formatChanges == 1)
        #expect(abs(out.prefix(while: { $0 == 0 }).count - 6_400) <= 4)
        #expect(abs(out.count - 8_000) <= 4)
        // The same format again is not a change.
        _ = pipeline.ingest(
            TapBuffer(
                samples: Synth.sine(frequency: 440, rate: 16_000, frames: 1_600, channels: 1), channels: 1,
                sampleRate: 16_000, hostTime: 1_600_000_000))
        #expect(pipeline.formatChanges == 1)
    }

    @Test func aFormatChangeKeepsTheTimeline() {
        var pipeline = SystemAudioPipeline(converter: .identity)
        _ = pipeline.ingest(buffer(frames: 4_800, at: 1_000))
        let other = TapBuffer(
            samples: Synth.sine(frequency: 440, rate: 44_100, frames: 4_410, channels: 1), channels: 1,
            sampleRate: 44_100, hostTime: 1_100_000_000)
        let out = pipeline.ingest(other)
        #expect(abs(out.count - 1_600) <= 3)
    }
}

@Suite struct SystemAudioSourceTests {
    private func buffer(at ms: UInt64, frames: Int = 4_800, startFrame: Int = 0) -> TapBuffer {
        TapBuffer(
            samples: Synth.sine(frequency: 440, rate: 48_000, frames: frames, startFrame: startFrame),
            channels: 2, sampleRate: 48_000, hostTime: ms * 1_000_000)
    }

    private func source(
        _ backend: FakeBackend, clock: FakeClock, enabled: Bool = true, anchor: UInt64? = nil,
        events: EventLog = EventLog()
    ) -> SystemAudioSource {
        SystemAudioSource(
            backend: backend, clock: clock, converter: .identity, enabled: enabled, anchorHostTime: anchor,
            restartDelay: .zero, sleeper: { _ in }, onEvent: { event in events.append(event) })
    }

    @Test func theTapExcludesLintelAndDeliversConvertedChunks() async throws {
        let backend = FakeBackend()
        let clock = FakeClock(1_000_000_000)
        let source = source(backend, clock: clock)
        let collector = StreamCollector(try await source.start { _ in })
        #expect(backend.excludingFlags == [true])
        backend.deliver(buffer(at: 1_000))
        backend.deliver(buffer(at: 1_100, startFrame: 4_800))
        clock.set(1_200_000_000)
        await source.stop()
        let samples = await collector.finished()
        #expect(abs(samples.count - 3_200) <= 4)
        #expect(Synth.rms(samples) > 0.3)
        #expect(backend.stoppedFlags == [true])
        #expect(backend.observationCancelled)
    }

    @Test func aDisabledFlagThrowsTheTypedFailureWithoutTouchingCoreAudio() async {
        let backend = FakeBackend()
        let source = source(backend, clock: FakeClock(), enabled: false)
        await #expect(throws: SystemAudioError.disabled) { _ = try await source.start { _ in } }
        #expect(backend.tapCount == 0)
    }

    @Test func aTapThatCannotStartThrowsAndLeavesNothingRunning() async {
        let backend = FakeBackend()
        backend.failNext([.permissionDenied])
        let source = source(backend, clock: FakeClock())
        await #expect(throws: SystemAudioError.permissionDenied) { _ = try await source.start { _ in } }
        #expect(backend.tapCount == 0)
        // Nothing was ever observed or left behind.
        #expect(backend.observationCount == 0)
        #expect(!backend.observationCancelled)
    }

    @Test func aBufferWithoutAValidStampIsPlacedByTheClock() async throws {
        let backend = FakeBackend()
        let clock = FakeClock(1_000_000_000)
        let source = source(backend, clock: clock, anchor: 1_000_000_000)
        let collector = StreamCollector(try await source.start { _ in })
        clock.set(1_250_000_000)
        var invalid = buffer(at: 0)
        invalid.hostTimeValid = false
        backend.deliver(invalid)
        // A zero stamp counts as invalid too, and the next buffer is not dropped.
        clock.set(1_350_000_000)
        backend.deliver(buffer(at: 0, startFrame: 4_800))
        clock.set(1_450_000_000)
        await source.stop()
        let samples = await collector.finished()
        #expect(abs(samples.count - 7_200) <= 8)  // 450 ms
        #expect(abs(samples.prefix(while: { $0 == 0 }).count - 4_000) <= 8)
        #expect(Synth.rms(Array(samples.suffix(3_000))) > 0.3)
    }

    @Test func aDeviceChangeDuringStartDoesNotLeakATap() async throws {
        let backend = FakeBackend()
        backend.fireChangeWhileObserving()
        let source = source(backend, clock: FakeClock(1_000_000_000))
        _ = try await source.start { _ in }
        try await waitUntil { backend.tapCount == 2 }
        // The first tap was found by the recreation and stopped; only the second one runs.
        try await waitUntil { backend.stoppedFlags == [true, false] }
        await source.stop()
        #expect(backend.stoppedFlags == [true, true])
    }

    @Test func recreatingNeverLeavesALiveSessionBehind() async throws {
        let backend = FakeBackend()
        let source = source(backend, clock: FakeClock(1_000_000_000))
        _ = try await source.start { _ in }
        for expected in 2...4 {
            backend.changeOutputDevice()
            try await waitUntil { backend.tapCount == expected }
        }
        await source.stop()
        try await waitUntil { backend.stoppedFlags.allSatisfy { $0 } }
    }

    @Test func aSourceCanBeStartedAgainAfterStopWithAFreshTimeline() async throws {
        let backend = FakeBackend()
        let clock = FakeClock(1_000_000_000)
        let source = source(backend, clock: clock)
        let first = StreamCollector(try await source.start { _ in })
        backend.deliver(buffer(at: 1_000))
        clock.set(1_500_000_000)
        await source.stop()
        #expect(abs(await first.finished().count - 8_000) <= 6)

        clock.set(5_000_000_000)
        #expect(source.anchorHostTime != 5_000_000_000)
        let second = StreamCollector(try await source.start { _ in })
        #expect(source.anchorHostTime == 5_000_000_000)
        backend.deliver(buffer(at: 5_000))
        clock.set(5_100_000_000)
        await source.stop()
        let samples = await second.finished()
        #expect(abs(samples.count - 1_600) <= 4)  // no padding carried over from the first run
        #expect(backend.tapCount == 2)
        #expect(backend.stoppedFlags == [true, true])
    }

    @Test func aListenerThatCannotBeInstalledIsReportedAndCaptureContinues() async throws {
        let backend = FakeBackend()
        backend.failObservation(.tapUnavailable(-7))
        let events = EventLog()
        let source = source(backend, clock: FakeClock(1_000_000_000), events: events)
        let collector = StreamCollector(try await source.start { _ in })
        #expect(events.value == [.outputChangesNotObserved(.tapUnavailable(-7))])
        backend.deliver(buffer(at: 1_000))
        await source.stop()
        #expect(!(await collector.finished()).isEmpty)
        #expect(backend.stoppedFlags == [true])
    }

    @Test func aFormatChangeAndAResyncAreReportedAsEvents() async throws {
        let backend = FakeBackend()
        let events = EventLog()
        let source = source(backend, clock: FakeClock(1_000_000_000), events: events)
        _ = try await source.start { _ in }
        backend.deliver(buffer(at: 1_000))
        backend.deliver(
            TapBuffer(
                samples: Synth.sine(frequency: 440, rate: 16_000, frames: 1_600, channels: 1), channels: 1,
                sampleRate: 16_000, hostTime: 1_100_000_000))
        #expect(events.value == [.formatChanged])
        backend.deliver(buffer(at: 1_100 + 3_600_000))
        #expect(events.value == [.formatChanged, .formatChanged, .timelineResynced])
        await source.stop()
    }

    @Test func aDeviceChangeRecreatesTheTapAndFillsTheGapWithSilence() async throws {
        let backend = FakeBackend()
        let clock = FakeClock(1_000_000_000)
        let events = EventLog()
        let source = source(backend, clock: clock, events: events)
        let collector = StreamCollector(try await source.start { _ in })
        backend.deliver(buffer(at: 1_000))  // 0..100 ms
        backend.changeOutputDevice()
        try await waitUntil { backend.tapCount == 2 }
        #expect(backend.stoppedFlags == [true, false])
        // The old tap is retired: its late buffer is ignored.
        backend.deliver(buffer(at: 1_100, startFrame: 4_800), tap: 0)
        // The new tap's first buffer comes 900 ms later, on a 44.1 kHz device.
        backend.deliver(
            TapBuffer(
                samples: Synth.sine(frequency: 440, rate: 44_100, frames: 4_410, channels: 1), channels: 1,
                sampleRate: 44_100, hostTime: 2_000_000_000))
        clock.set(2_100_000_000)
        await source.stop()
        let samples = await collector.finished()
        // 1.1 s of timeline: 100 ms audio, 900 ms silence, 100 ms audio.
        #expect(abs(samples.count - 17_600) <= 6)
        let silent = samples.dropFirst(1_600).prefix(while: { $0 == 0 }).count
        #expect(abs(silent - 14_400) <= 8)
        #expect(events.value == [.recreated])
        #expect(backend.stoppedFlags == [true, true])
    }

    @Test func aFailedRecreateKeepsTheTimelineMovingAndReports() async throws {
        let backend = FakeBackend()
        let clock = FakeClock(1_000_000_000)
        let events = EventLog()
        let source = source(backend, clock: clock, events: events)
        let collector = StreamCollector(try await source.start { _ in })
        backend.deliver(buffer(at: 1_000))
        backend.failNext([.tapUnavailable(-1), .tapUnavailable(-1), .tapUnavailable(-1)])
        clock.set(1_500_000_000)
        backend.changeOutputDevice()
        try await waitUntil { !events.value.isEmpty }
        #expect(events.value == [.recreateFailed(.tapUnavailable(-1))])
        await source.stop()
        let samples = await collector.finished()
        #expect(abs(samples.count - 8_000) <= 6)  // 500 ms
    }

    @Test func recreateRetriesBeforeGivingUp() async throws {
        let backend = FakeBackend()
        let events = EventLog()
        let source = source(backend, clock: FakeClock(1_000_000_000), events: events)
        _ = try await source.start { _ in }
        backend.failNext([.tapUnavailable(-1)])
        backend.changeOutputDevice()
        try await waitUntil { !events.value.isEmpty }
        #expect(events.value == [.recreated])
        #expect(backend.tapCount == 2)
        await source.stop()
    }

    @Test func stopAndDeinitReleaseTheTap() async throws {
        let backend = FakeBackend()
        do {
            let source = source(backend, clock: FakeClock(1_000_000_000))
            _ = try await source.start { _ in }
            #expect(backend.stoppedFlags == [false])
        }
        #expect(backend.stoppedFlags == [true])
        #expect(backend.observationCancelled)
    }

    @Test func theAnchorIsTheStartRequestWhenNoneIsGiven() async throws {
        let backend = FakeBackend()
        let source = source(backend, clock: FakeClock(7_000_000_000))
        _ = try await source.start { _ in }
        #expect(source.anchorHostTime == 7_000_000_000)
        await source.stop()
    }
}

@Suite struct SelfTestTests {
    private func tone(rate: Double = 48_000) -> TapBuffer {
        TapBuffer(
            samples: Synth.sine(frequency: 880, rate: rate, frames: 4_800), channels: 2, sampleRate: rate, hostTime: 1)
    }

    private func run(backend: FakeBackend, player: FakeTonePlayer) async -> SystemAudioSelfTest.Verdict {
        await SystemAudioSelfTest(backend: backend, player: player, settle: .zero, sleeper: { _ in }).run()
    }

    @Test func aTapThatHearsTheSignalWorks() async {
        let backend = FakeBackend()
        let player = FakeTonePlayer { backend.deliver(tone()) }
        #expect(await run(backend: backend, player: player) == .works)
        #expect(player.played.withLock { $0 } == [0.3])
        // Lintel is not excluded, or the tap would never hear its own tone.
        #expect(backend.excludingFlags == [false])
        #expect(backend.stoppedFlags == [true])
    }

    @Test func onlyZerosMeanSilent() async {
        let backend = FakeBackend()
        let player = FakeTonePlayer {
            backend.deliver(
                TapBuffer(samples: [Float](repeating: 0, count: 9_600), channels: 2, sampleRate: 48_000, hostTime: 1))
        }
        #expect(await run(backend: backend, player: player) == .silent)
        #expect(backend.stoppedFlags == [true])
    }

    @Test func noBuffersAtAllMeanTheTapNeverRan() async {
        let backend = FakeBackend()
        #expect(await run(backend: backend, player: FakeTonePlayer()) == .unavailable(.noData))
        #expect(backend.stoppedFlags == [true])
    }

    @Test func nonFiniteSamplesNeverCountAsASignal() async {
        let backend = FakeBackend()
        let player = FakeTonePlayer {
            backend.deliver(
                TapBuffer(samples: [.nan, .infinity, 0, 0], channels: 2, sampleRate: 48_000, hostTime: 1))
        }
        #expect(await run(backend: backend, player: player) == .silent)
    }

    @Test func aPlayerThatNeverReturnsTimesOutInsteadOfHanging() async throws {
        let backend = FakeBackend()
        let player = HangingTonePlayer()
        let test = SystemAudioSelfTest(
            backend: backend, player: player, settle: .zero, sleeper: { _ in }, timeoutSleeper: { _ in })
        #expect(await test.run() == .unavailable(.timedOut))
        #expect(backend.stoppedFlags == [true])
        try await waitUntil { player.isWaiting }
        player.release()
    }

    @Test func aPlayerErrorIsKeptNotFlattened() async {
        struct Boom: Error {}
        let backend = FakeBackend()
        let verdict = await run(backend: backend, player: FakeTonePlayer(error: Boom()))
        guard case .unavailable(.tonePlayerFailed) = verdict else {
            Issue.record("expected tonePlayerFailed, got \(verdict)")
            return
        }
        let coded = await run(
            backend: FakeBackend(),
            player: FakeTonePlayer(error: NSError(domain: "com.apple.coreaudio.avfaudio", code: -10_868)))
        #expect(coded == .unavailable(.tonePlayerFailed(-10_868)))
    }

    @Test func aTapFailureIsReportedNotSilent() async {
        let backend = FakeBackend()
        backend.failNext([.tapUnavailable(-50)])
        #expect(await run(backend: backend, player: FakeTonePlayer()) == .unavailable(.tapUnavailable(-50)))
    }

    @Test func aPlayerFailureStopsTheTap() async {
        let backend = FakeBackend()
        let verdict = await run(backend: backend, player: FakeTonePlayer(failure: true))
        #expect(verdict == .unavailable(.unsupportedFormat))
        #expect(backend.stoppedFlags == [true])
    }
}

@Suite struct WAVSourceTests {
    @Test func readsAMono16kHzWAVInChunks() async throws {
        let samples = Synth.sine(frequency: 220, rate: 16_000, frames: 4_000, channels: 1)
        let source = try WAVFileAudioSource(data: Synth.wav16(samples), chunkSamples: 1_000)
        let stream = try await source.start { _ in }
        var chunks: [[Float]] = []
        for await chunk in stream { chunks.append(chunk) }
        #expect(chunks.map(\.count) == [1_000, 1_000, 1_000, 1_000])
        let joined = chunks.flatMap { $0 }
        #expect(zip(joined, samples).allSatisfy { abs($0 - $1) < 1e-3 })
    }

    @Test func readsAFileFromDisk() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "tone.wav")
        try Synth.wav16(Synth.sine(frequency: 220, rate: 16_000, frames: 800, channels: 1)).write(to: url)
        let source = try WAVFileAudioSource(url: url)
        var count = 0
        for await chunk in try await source.start(onLevel: { _ in }) { count += chunk.count }
        #expect(count == 800)
    }

    @Test func rejectsOtherRatesChannelsAndNonWAV() {
        #expect(throws: WAVError.self) { _ = try WAVFile.samples(from: Synth.wav16([0, 0], rate: 48_000)) }
        #expect(throws: WAVError.self) { _ = try WAVFile.samples(from: Synth.wav16([0, 0], channels: 2)) }
        #expect(throws: WAVError.notWAV) { _ = try WAVFile.samples(from: Data("hello".utf8)) }
    }
}

@Suite struct HostileWAVTests {
    private func riff(_ chunks: [(String, [UInt8])], declaredSizes: [UInt32?] = []) -> Data {
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: Array("WAVE".utf8))
        for (index, chunk) in chunks.enumerated() {
            data.append(contentsOf: Array(chunk.0.utf8))
            let size = (index < declaredSizes.count ? declaredSizes[index] : nil) ?? UInt32(chunk.1.count)
            withUnsafeBytes(of: size.littleEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: chunk.1)
            if chunk.1.count % 2 == 1 { data.append(0) }
        }
        return data
    }

    private let goodFormat: [UInt8] = [1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0]

    @Test func aFormatChunkShorterThanSixteenBytesIsRejected() {
        // 8 declared bytes: the old check read 16 bytes into the following chunk.
        let short = riff([("fmt ", Array(goodFormat.prefix(8))), ("data", [0, 0, 0, 0])])
        #expect(throws: WAVError.notWAV) { _ = try WAVFile.samples(from: short) }
        let empty = riff([("fmt ", []), ("data", [0, 0])])
        #expect(throws: WAVError.notWAV) { _ = try WAVFile.samples(from: empty) }
    }

    @Test func aDataChunkBeforeTheFormatIsRejected() {
        #expect(throws: WAVError.notWAV) {
            _ = try WAVFile.samples(from: riff([("data", [0, 0]), ("fmt ", goodFormat)]))
        }
    }

    @Test func aMissingDataChunkIsRejected() {
        #expect(throws: WAVError.notWAV) { _ = try WAVFile.samples(from: riff([("fmt ", goodFormat)])) }
    }

    @Test func truncatedHeadersAreRejectedWithoutTrapping() {
        let whole = riff([("fmt ", goodFormat), ("data", [1, 0, 2, 0])])
        for length in 0..<whole.count - 1 where length < 36 {
            #expect(throws: WAVError.self) { _ = try WAVFile.samples(from: whole.prefix(length)) }
        }
    }

    @Test func aDataSizeBeyondTheFileIsClampedToWhatExists() throws {
        let data = riff([("fmt ", goodFormat), ("data", [1, 0, 2, 0])], declaredSizes: [nil, 0xFFFF_FFFF])
        let samples = try WAVFile.samples(from: data)
        #expect(samples.count == 2)
    }

    @Test func aHugeUnknownChunkSizeEndsTheScanCleanly() {
        let data = riff([("junk", [1, 2, 3]), ("fmt ", goodFormat)], declaredSizes: [0xFFFF_FFFF, nil])
        #expect(throws: WAVError.notWAV) { _ = try WAVFile.samples(from: data) }
    }

    @Test func anEmptyDataChunkIsEmptyAudio() throws {
        #expect(try WAVFile.samples(from: riff([("fmt ", goodFormat), ("data", [])])).isEmpty)
    }

    @Test func nonFiniteFloatSamplesBecomeSilence() throws {
        var format = goodFormat
        format[0] = 3
        format[14] = 32
        var body: [UInt8] = []
        for value in [Float.nan, .infinity, 0.5] {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { body.append(contentsOf: $0) }
        }
        let samples = try WAVFile.samples(from: riff([("fmt ", format), ("data", body)]))
        #expect(samples == [0, 0, 0.5])
    }
}

@Suite struct TapRingTests {
    @Test func buffersComeOutInOrderWithTheirMetadata() throws {
        let ring = TapRing(slotCount: 4, slotCapacity: 8)
        for index in 0..<3 {
            let slot = try #require(ring.reserve())
            for position in 0..<4 { slot[position] = Float(index * 10 + position) }
            ring.commit(count: 4, channels: 2, sampleRate: 48_000, hostTime: UInt64(index), hostTimeValid: index != 1)
        }
        for index in 0..<3 {
            let buffer = try #require(ring.pop())
            #expect(buffer.samples == (0..<4).map { Float(index * 10 + $0) })
            #expect(buffer.channels == 2)
            #expect(buffer.sampleRate == 48_000)
            #expect(buffer.hostTime == UInt64(index))
            #expect(buffer.hostTimeValid == (index != 1))
        }
        #expect(ring.pop() == nil)
    }

    @Test func aFullRingDropsInsteadOfBlockingOrOverwriting() throws {
        let ring = TapRing(slotCount: 2, slotCapacity: 4)
        for index in 0..<2 {
            let slot = try #require(ring.reserve())
            slot[0] = Float(index)
            ring.commit(count: 1, channels: 1, sampleRate: 16_000, hostTime: 0, hostTimeValid: true)
        }
        #expect(ring.reserve() == nil)
        #expect(ring.dropped == 1)
        #expect(try #require(ring.pop()).samples == [0])
        // A slot is free again, and the surviving buffers keep their order.
        let slot = try #require(ring.reserve())
        slot[0] = 2
        ring.commit(count: 1, channels: 1, sampleRate: 16_000, hostTime: 0, hostTimeValid: true)
        #expect(try #require(ring.pop()).samples == [1])
        #expect(try #require(ring.pop()).samples == [2])
    }

    @Test func aProducerAndAConsumerOnTwoThreadsLoseNothingThatWasAccepted() async {
        let ring = TapRing(slotCount: 8, slotCapacity: 4)
        let total = 20_000
        let producer = Task.detached {
            var accepted = 0
            for value in 0..<total {
                if let slot = ring.reserve() {
                    slot[0] = Float(value)
                    ring.commit(count: 1, channels: 1, sampleRate: 1, hostTime: UInt64(value), hostTimeValid: true)
                    accepted += 1
                }
            }
            return accepted
        }
        let consumer = Task.detached {
            var received: [Float] = []
            while !Task.isCancelled {
                if let buffer = ring.pop() { received.append(buffer.samples[0]) } else { await Task.yield() }
            }
            while let buffer = ring.pop() { received.append(buffer.samples[0]) }
            return received
        }
        let accepted = await producer.value
        consumer.cancel()
        let received = await consumer.value
        #expect(received.count == accepted)
        #expect(zip(received, received.dropFirst()).allSatisfy { $0 < $1 })
        #expect(accepted + ring.dropped == total)
    }
}

@Suite struct TapLayoutTests {
    private typealias Buffer = (channels: Int, bytes: Int)

    private func select(_ buffers: [Buffer], channels: Int, planar: Bool = false) -> TapLayout.Selection? {
        TapLayout.select(count: buffers.count, tapChannels: channels, nonInterleaved: planar) { buffers[$0] }
    }

    @Test func theTapStreamIsMatchedByChannelsNotByPosition() {
        // A device input stream (1 channel) first, the stereo tap last.
        let selection = select([(1, 400), (2, 960)], channels: 2)
        #expect(selection == TapLayout.Selection(firstBuffer: 1, bufferCount: 1, frames: 120))
    }

    @Test func theLastMatchingStreamWins() {
        let selection = select([(2, 800), (2, 1_600)], channels: 2)
        #expect(selection?.firstBuffer == 1)
        #expect(selection?.frames == 200)
    }

    @Test func noMatchingStreamIsNoSelection() {
        #expect(select([(1, 400)], channels: 2) == nil)
        #expect(select([], channels: 2) == nil)
        #expect(select([(2, 4)], channels: 2) == nil)  // less than one frame
        #expect(select([(2, 800)], channels: 0) == nil)
    }

    @Test func nonInterleavedUsesTheTrailingBuffersAndTheShortestFrameCount() {
        // Three buffers for a stereo tap: the first one belongs to something else.
        let selection = select([(1, 4_000), (1, 400), (1, 392)], channels: 2, planar: true)
        #expect(selection == TapLayout.Selection(firstBuffer: 1, bufferCount: 2, frames: 98))
    }

    @Test func nonInterleavedNeverReadsMoreFramesThanTheSmallestBufferHolds() {
        let selection = select([(1, 400), (1, 40)], channels: 2, planar: true)
        #expect(selection?.frames == 10)
    }

    @Test func nonInterleavedNeedsOneMonoBufferPerChannel() {
        #expect(select([(1, 400)], channels: 2, planar: true) == nil)
        #expect(select([(2, 400), (2, 400)], channels: 2, planar: true) == nil)
    }

    @Test func aMonoPlanarTapIsTheSameAsInterleaved() {
        #expect(
            select([(1, 400)], channels: 1, planar: true)
                == TapLayout.Selection(firstBuffer: 0, bufferCount: 1, frames: 100))
    }
}

@Suite struct SettingsFlagTests {
    @Test func systemAudioDefaultsToOn() {
        let settings = MemorySettingsStore()
        let plugin = PluginSettings(pluginID: "meetings", store: settings)
        #expect(MeetingsSettings(plugin).systemAudio)
        MeetingsSettings(plugin).setSystemAudio(false)
        #expect(!MeetingsSettings(plugin).systemAudio)
        #expect(settings.value(forKey: "plugins.meetings.systemAudio") == .bool(false))
    }
}

import Foundation
import PounceKit
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
        #expect(out.first != 0 || Synth.rms(out) > 0.3)

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

    @Test func theTapExcludesPounceAndDeliversConvertedChunks() async throws {
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
        #expect(!backend.observationCancelled || backend.tapCount == 0)
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
        // Pounce is not excluded, or the tap would never hear its own tone.
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

    @Test func noBuffersAtAllMeanSilent() async {
        #expect(await run(backend: FakeBackend(), player: FakeTonePlayer()) == .silent)
    }

    @Test func aTapFailureIsReportedNotSilent() async {
        let backend = FakeBackend()
        backend.failNext([.tapUnavailable(-50)])
        #expect(await run(backend: backend, player: FakeTonePlayer()) == .unavailable(.tapUnavailable(-50)))
    }

    @Test func aPlayerFailureStopsTheTap() async {
        let backend = FakeBackend()
        let verdict = await run(backend: backend, player: FakeTonePlayer(failure: true))
        #expect(verdict == .unavailable(.tapUnavailable(-1)))
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

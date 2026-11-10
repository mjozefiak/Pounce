import ApplicationServices
import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// Step 1.8a: the checked lookup of the private window id function and its start-up self-check, with an injected
/// resolver. The real function against a real system is a manual item (`docs/qa.md`).
@Suite struct WindowIDLookupTests {
    private let element = AXUIElementCreateApplication(1)

    @Test func aMissingSymbolMakesTheLookupUnavailable() {
        let lookup = WindowIDLookup(resolver: { nil })
        #expect(!lookup.isAvailable)
        #expect(lookup.windowID(of: element) == nil)
    }

    @Test func theLiveResolverNeverCrashesWhateverTheSystemHolds() {
        // On this Mac the symbol may or may not exist; either way the lookup answers, and an element that is not a
        // window gives nil instead of a bogus number.
        let lookup = WindowIDLookup.live
        _ = lookup.isAvailable
        #expect(lookup.windowID(of: element) == nil)
    }

    @Test func aFoundSymbolIsCalledAndZeroOrAnErrorMeansUnknown() {
        // A C function with the right signature stands in for the private one.
        let ok: WindowIDLookup.Function = { _, out in
            out.pointee = 4_242
            return .success
        }
        let failing: WindowIDLookup.Function = { _, _ in .failure }
        let zero: WindowIDLookup.Function = { _, out in
            out.pointee = 0
            return .success
        }
        #expect(
            WindowIDLookup(resolver: { unsafeBitCast(ok, to: UnsafeMutableRawPointer.self) }).windowID(of: element)
                == 4_242)
        #expect(
            WindowIDLookup(resolver: { unsafeBitCast(failing, to: UnsafeMutableRawPointer.self) }).windowID(of: element)
                == nil)
        #expect(
            WindowIDLookup(resolver: { unsafeBitCast(zero, to: UnsafeMutableRawPointer.self) }).windowID(of: element)
                == nil)
    }

    @Test func theSelfCheckTable() {
        func verdict(_ available: Bool, _ samples: [(UInt32?, UInt32)]) -> (WindowClientAvailability, Bool) {
            let result = WindowIDSelfCheck.evaluate(
                symbolAvailable: available, samples: samples.map { WindowIDSample(reported: $0.0, expected: $0.1) })
            return (result.availability, result.isVerified)
        }
        #expect(verdict(false, []).0 == .unsupported(reason: WindowIDSelfCheck.missingReason))
        // No comparable window yet: available, not verified.
        #expect(verdict(true, []) == (.available, false))
        #expect(verdict(true, [(10, 10), (11, 11)]) == (.available, true))
        // One failed answer is ignored while another agrees.
        #expect(verdict(true, [(nil, 10), (11, 11)]) == (.available, true))
        // A wrong answer is a mismatch, even next to right ones.
        #expect(verdict(true, [(10, 10), (99, 11)]).0 == .unsupported(reason: WindowIDSelfCheck.mismatchReason))
        // Nothing but failed answers is a mismatch.
        #expect(verdict(true, [(nil, 10), (nil, 11)]).0 == .unsupported(reason: WindowIDSelfCheck.mismatchReason))
    }

    @Test func theGuardRepeatsTheCheckUntilItCouldBeVerified() {
        let sampler = ScriptedSampler([[], [], [WindowIDSample(reported: 5, expected: 5)]])
        let guardian = WindowIDGuard(lookup: WindowIDLookup(read: { _ in 1 }), sampler: sampler)
        #expect(guardian.availability == .available)
        #expect(guardian.availability == .available)
        #expect(sampler.calls == 2)
        #expect(guardian.availability == .available)
        // Verified: the sampler is not asked again.
        #expect(guardian.availability == .available)
        #expect(sampler.calls == 3)
    }

    @Test func aWrongAnswerIsKeptAsUnsupportedWithoutSamplingAgain() {
        let sampler = ScriptedSampler([[WindowIDSample(reported: 1, expected: 2)]])
        let guardian = WindowIDGuard(lookup: WindowIDLookup(read: { _ in 1 }), sampler: sampler)
        #expect(guardian.availability == .unsupported(reason: WindowIDSelfCheck.mismatchReason))
        #expect(guardian.availability == .unsupported(reason: WindowIDSelfCheck.mismatchReason))
        #expect(sampler.calls == 1)
    }

    @Test func aMissingSymbolNeverSamples() {
        let sampler = ScriptedSampler([[]])
        let guardian = WindowIDGuard(lookup: WindowIDLookup(resolver: { nil }), sampler: sampler)
        #expect(guardian.availability == .unsupported(reason: WindowIDSelfCheck.missingReason))
        #expect(sampler.calls == 0)
    }

    @Test func aFrameMatchesOnlyWhenExactlyOneListedWindowFitsIt() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let one = SystemWindowIDSampler.ListedWindow(number: 1, pid: 5, bounds: frame)
        let twin = SystemWindowIDSampler.ListedWindow(number: 2, pid: 5, bounds: frame.offsetBy(dx: 1, dy: 0))
        let other = SystemWindowIDSampler.ListedWindow(
            number: 3, pid: 5, bounds: CGRect(x: 400, y: 20, width: 300, height: 200))
        #expect(SystemWindowIDSampler.uniqueMatch(for: frame, in: [one, other]) == one)
        #expect(SystemWindowIDSampler.uniqueMatch(for: frame, in: [one, twin, other]) == nil)
        #expect(SystemWindowIDSampler.uniqueMatch(for: frame, in: [other]) == nil)
    }
}

private final class ScriptedSampler: WindowIDSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[WindowIDSample]]
    private(set) var calls = 0

    init(_ script: [[WindowIDSample]]) { self.script = script }

    func samples(using lookup: WindowIDLookup) -> [WindowIDSample] {
        lock.withLock {
            calls += 1
            return script.isEmpty ? [] : (script.count > 1 ? script.removeFirst() : script[0])
        }
    }
}

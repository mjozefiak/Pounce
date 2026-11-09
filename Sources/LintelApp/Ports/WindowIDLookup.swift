import ApplicationServices
import CoreGraphics
import Foundation
import LintelKit
import Synchronization

/// The window number of an `AXUIElement`. Accessibility has no public API for it; every comparable tool uses the
/// private function `_AXUIElementGetWindow` (owner decision Q3, ADR 0009, spec: Architecture).
///
/// The symbol is looked up with `dlsym` at run time, never linked, and its absence is an ordinary state: the
/// lookup reports itself unavailable and `WindowIDGuard` turns that into `.unsupported`. There is no fallback in
/// v1: the failure mode is a disabled feature, never a crash and never parked windows. Nothing here traps.
nonisolated struct WindowIDLookup: Sendable {
    /// `AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *)`.
    typealias Function = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let symbolName = "_AXUIElementGetWindow"

    /// Whether the function was found.
    let isAvailable: Bool
    private let read: @Sendable (AXUIElement) -> UInt32?

    /// - Parameter resolver: finds the symbol's address, or `nil` when it is missing. Injected so a test can
    ///   simulate a missing symbol.
    init(resolver: () -> UnsafeMutableRawPointer?) {
        guard let address = resolver() else {
            isAvailable = false
            read = { _ in nil }
            return
        }
        // The address is that of a C function with the signature above; calling it is checked below (an error or
        // a zero answer is "unknown", never a window id).
        let function = unsafeBitCast(address, to: Function.self)
        isAvailable = true
        read = { element in
            var number: CGWindowID = 0
            guard function(element, &number) == .success, number != 0 else { return nil }
            return number
        }
    }

    /// A lookup that answers with `answers` (tests of everything above the private call).
    init(isAvailable: Bool = true, read: @escaping @Sendable (AXUIElement) -> UInt32?) {
        self.isAvailable = isAvailable
        self.read = read
    }

    /// The real lookup: `dlsym` over the symbols of the running process.
    static let live = WindowIDLookup(resolver: {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        return dlsym(handle, symbolName)
    })

    /// The window number, or `nil` when the element is not a window or the function failed.
    func windowID(of element: AXUIElement) -> UInt32? { read(element) }
}

/// One comparison of what the private function says with what `CGWindowList` says for the same window.
nonisolated struct WindowIDSample: Equatable, Sendable {
    /// The number `_AXUIElementGetWindow` returned; `nil` when it failed.
    var reported: UInt32?
    /// The number `CGWindowList` gives for the same window.
    var expected: UInt32
}

/// Decides whether the private function can be trusted (the start-up self-check, spec: Architecture).
nonisolated enum WindowIDSelfCheck {
    static let missingReason = "The window id function is missing"
    static let mismatchReason = "The window id function disagrees with the window list"

    /// - No symbol: unsupported.
    /// - A sample whose answer differs from the window list: unsupported. An answer that failed (`nil`) is
    ///   ignored as long as one sample agrees, and counts as a mismatch when none does.
    /// - No sample at all (no window could be compared yet, or Accessibility is not trusted): available, but
    ///   not yet verified (`isVerified` is false), so the check runs again at the next chance.
    static func evaluate(symbolAvailable: Bool, samples: [WindowIDSample]) -> (
        availability: WindowClientAvailability, isVerified: Bool
    ) {
        guard symbolAvailable else { return (.unsupported(reason: missingReason), true) }
        guard !samples.isEmpty else { return (.available, false) }
        if samples.contains(where: { $0.reported != nil && $0.reported != $0.expected }) {
            return (.unsupported(reason: mismatchReason), true)
        }
        if !samples.contains(where: { $0.reported == $0.expected }) {
            return (.unsupported(reason: mismatchReason), true)
        }
        return (.available, true)
    }
}

/// Compares the lookup with the window list for a few real windows.
nonisolated protocol WindowIDSampling: Sendable {
    func samples(using lookup: WindowIDLookup) -> [WindowIDSample]
}

/// Holds the verdict of the self-check: computed on first use, kept once it is verified, and repeated while it
/// could not be verified yet (no comparable window).
nonisolated final class WindowIDGuard: Sendable {
    private struct State {
        var availability: WindowClientAvailability?
        var isVerified = false
    }

    private let lookup: WindowIDLookup
    private let sampler: any WindowIDSampling
    private let state = Mutex(State())

    init(lookup: WindowIDLookup, sampler: any WindowIDSampling) {
        self.lookup = lookup
        self.sampler = sampler
    }

    var availability: WindowClientAvailability {
        let cached = state.withLock { $0.isVerified ? $0.availability : nil }
        if let cached { return cached }
        let samples = lookup.isAvailable ? sampler.samples(using: lookup) : []
        let result = WindowIDSelfCheck.evaluate(symbolAvailable: lookup.isAvailable, samples: samples)
        state.withLock {
            $0.availability = result.availability
            $0.isVerified = result.isVerified
        }
        return result.availability
    }
}

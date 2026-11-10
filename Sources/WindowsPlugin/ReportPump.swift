import CoreGraphics
import Foundation
import LintelKit

/// What the engine reports to the runtime, in the order it produced it.
enum EngineReport: Sendable {
    case hud(WorkspaceID, windowCount: Int)
    case summary(WorkspaceSummary)
    case banner(EngineBanner)
    case windowMoved(WindowID, CGRect)
    case restored(RecoveryReport)
}

/// Carries the engine's reports to the main actor through one ordered stream and one task, so they are handled
/// in the order they were produced.
@MainActor
final class ReportPump {
    private enum Item: Sendable {
        case report(EngineReport)
        #if DEBUG
        /// Resumed when every item before it has been handled (`waitUntilHandled()`).
        case marker(CheckedContinuation<Void, Never>)
        #endif
    }

    private let continuation: AsyncStream<Item>.Continuation
    private var task: Task<Void, Never>?
    private var closed = false
    /// The closures the engine calls; each puts one report on the stream.
    nonisolated let reporter: EngineReporter

    /// Set once by the owner (the runtime builds the pump before it can name itself).
    var handler: @MainActor (EngineReport) -> Void = { _ in }

    init(handle: @escaping @MainActor (EngineReport) -> Void = { _ in }) {
        handler = handle
        let (stream, continuation) = AsyncStream.makeStream(of: Item.self)
        self.continuation = continuation
        reporter = EngineReporter(
            hud: { workspace, count in continuation.yield(.report(.hud(workspace, windowCount: count))) },
            summary: { continuation.yield(.report(.summary($0))) },
            banner: { continuation.yield(.report(.banner($0))) },
            windowMoved: { id, frame in continuation.yield(.report(.windowMoved(id, frame))) },
            restored: { continuation.yield(.report(.restored($0))) })
        task = Task { @MainActor [weak self] in
            for await item in stream {
                switch item {
                case .report(let report): self?.deliver(report)
                #if DEBUG
                case .marker(let waiting): waiting.resume()
                #endif
                }
            }
        }
    }

    private func deliver(_ report: EngineReport) {
        if !closed { handler(report) }
    }

    deinit {
        continuation.finish()
    }

    /// Ends the pump: from this call on no report reaches the handler, also one that was already queued on the
    /// stream (no HUD or strip update after the plugin is off). The task drains what is buffered without handling
    /// it and then ends with the stream.
    func finish() {
        closed = true
        continuation.finish()
        task = nil
    }

    #if DEBUG
    /// Waits until everything reported so far has been handled (tests only). A pump that is freed first
    /// finishes its stream (`deinit`), and the task, which does not hold the pump, still drains the queued markers.
    func waitUntilHandled() async {
        await withCheckedContinuation { waiting in
            if case .terminated = continuation.yield(.marker(waiting)) { waiting.resume() }
        }
    }
    #endif
}

import Foundation
import Observation

/// The edit lock of one document and the state of its revise run (spec "Edit lock and revise run (state machine)"):
///
///     idle -> flushing -> waitingForModel -> generating -> validating -> applying -> idle
///
/// with the ends `cancelled`, `timedOut`, `rejected`, `conflict` (and `failed`, a store or model error: nothing was
/// changed either). The editor is read-only from `generating` to the end; during `flushing` and `waitingForModel`
/// it stays editable. The 10 minute timeout counts only the time spent in `generating`: leaving it (a yield to
/// dictation, validating) adds the time to `spent`, and entering it again starts from what is left. The lock reads
/// no clock: the service passes the instant in, so every edge is tested with an injected one.
@MainActor @Observable
final class EditLock {
    enum Phase: Equatable, Sendable, CaseIterable {
        case idle, flushing, waitingForModel, generating, validating, applying
        case cancelled, timedOut, rejected, conflict, failed

        /// A run is going on (not idle and not at an end).
        var isActive: Bool {
            switch self {
            case .flushing, .waitingForModel, .generating, .validating, .applying: true
            default: false
            }
        }

        var isEnd: Bool {
            switch self {
            case .cancelled, .timedOut, .rejected, .conflict, .failed: true
            default: false
            }
        }

        /// The editor cannot be typed in.
        var locksEditor: Bool {
            switch self {
            case .generating, .validating, .applying: true
            default: false
            }
        }
    }

    /// The edges of the machine. A run starts from `idle` or from an end (the next run), and every active phase can
    /// be cancelled except `applying`, whose write is one transaction and is never interrupted.
    static let edges: Set<Edge> = {
        var set = Set<Edge>()
        func add(_ from: Phase, _ to: [Phase]) { for target in to { set.insert(Edge(from: from, to: target)) } }
        add(.idle, [.flushing])
        add(.flushing, [.waitingForModel, .idle, .cancelled, .failed])
        add(.waitingForModel, [.generating, .idle, .cancelled, .failed])
        add(.generating, [.validating, .waitingForModel, .cancelled, .timedOut, .rejected, .failed])
        add(.validating, [.applying, .idle, .rejected, .cancelled, .failed])
        add(.applying, [.idle, .conflict, .failed])
        for end in Phase.allCases where end.isEnd { add(end, [.idle, .flushing]) }
        return set
    }()

    struct Edge: Hashable, Sendable {
        var from: Phase
        var to: Phase
    }

    private(set) var phase: Phase = .idle
    /// The limit of time in `generating`, summed over the run (a yield does not restart it).
    let generatingLimit: Duration
    private var spent: Duration = .zero
    private var generatingSince: Duration?

    init(generatingLimit: Duration = .seconds(600)) {
        self.generatingLimit = generatingLimit
    }

    var isActive: Bool { phase.isActive }
    var isLocked: Bool { phase.locksEditor }

    /// Moves along an allowed edge; `false` (and nothing changes) for any other. Entering `generating` and leaving it
    /// keep the time account; `now` is the clock's instant as a duration since its origin.
    @discardableResult
    func move(to next: Phase, at now: Duration = .zero) -> Bool {
        guard Self.edges.contains(Edge(from: phase, to: next)) else { return false }
        if phase == .generating, let since = generatingSince {
            spent += now - since
            generatingSince = nil
        }
        if next == .generating { generatingSince = now }
        if next == .flushing { spent = .zero }
        phase = next
        return true
    }

    /// What is left of the generating limit at `now`.
    func remaining(at now: Duration) -> Duration {
        var used = spent
        if phase == .generating, let since = generatingSince { used += now - since }
        return max(.zero, generatingLimit - used)
    }

    /// Back to `idle` after an end has been shown.
    func reset() {
        if phase.isEnd { phase = .idle }
    }
}

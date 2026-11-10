import Testing

@testable import NotesPlugin

/// Spec step 6.2: every edge of the edit lock's state machine, and the time account, on an injected clock.
@MainActor
@Suite struct EditLockTests {
    typealias Phase = EditLock.Phase

    /// The whole machine, written out once: anything not here is refused.
    private static let allowed: [Phase: Set<Phase>] = [
        .idle: [.flushing],
        .flushing: [.waitingForModel, .idle, .cancelled, .failed],
        .waitingForModel: [.generating, .idle, .cancelled, .failed],
        .generating: [.validating, .waitingForModel, .cancelled, .timedOut, .rejected, .failed],
        .validating: [.applying, .idle, .rejected, .cancelled, .failed],
        .applying: [.idle, .conflict, .failed],
        .cancelled: [.idle, .flushing], .timedOut: [.idle, .flushing], .rejected: [.idle, .flushing],
        .conflict: [.idle, .flushing], .failed: [.idle, .flushing],
    ]

    /// Gets a lock to `phase` along the main path.
    private func lock(at phase: Phase) -> EditLock {
        let lock = EditLock()
        let path: [Phase]
        switch phase {
        case .idle: path = []
        case .flushing: path = [.flushing]
        case .waitingForModel: path = [.flushing, .waitingForModel]
        case .generating: path = [.flushing, .waitingForModel, .generating]
        case .validating: path = [.flushing, .waitingForModel, .generating, .validating]
        case .applying: path = [.flushing, .waitingForModel, .generating, .validating, .applying]
        case .cancelled: path = [.flushing, .cancelled]
        case .timedOut: path = [.flushing, .waitingForModel, .generating, .timedOut]
        case .rejected: path = [.flushing, .waitingForModel, .generating, .rejected]
        case .conflict: path = [.flushing, .waitingForModel, .generating, .validating, .applying, .conflict]
        case .failed: path = [.flushing, .failed]
        }
        for step in path { #expect(lock.move(to: step, at: .zero)) }
        #expect(lock.phase == phase)
        return lock
    }

    @Test func everyPairOfPhasesIsAllowedExactlyWhenTheMachineSaysSo() {
        for from in Phase.allCases {
            for to in Phase.allCases {
                let lock = lock(at: from)
                let expected = Self.allowed[from]?.contains(to) ?? false
                #expect(lock.move(to: to, at: .zero) == expected, "\(from) -> \(to)")
                #expect(lock.phase == (expected ? to : from), "\(from) -> \(to)")
            }
        }
    }

    @Test func theEdgeTableMatchesTheLockItself() {
        let written = Set(Self.allowed.flatMap { from, targets in targets.map { EditLock.Edge(from: from, to: $0) } })
        #expect(written == EditLock.edges)
    }

    @Test func theEditorIsLockedFromGeneratingToTheEnd() {
        for phase in Phase.allCases {
            let expected = phase == .generating || phase == .validating || phase == .applying
            #expect(lock(at: phase).isLocked == expected, "\(phase)")
        }
        #expect(!lock(at: .flushing).isLocked)
        #expect(!lock(at: .waitingForModel).isLocked)
    }

    @Test func activeAndEndPhases() {
        #expect(
            Phase.allCases.filter(\.isActive) == [.flushing, .waitingForModel, .generating, .validating, .applying])
        #expect(Phase.allCases.filter(\.isEnd) == [.cancelled, .timedOut, .rejected, .conflict, .failed])
    }

    @Test func onlyTimeInGeneratingCountsAgainstTheLimit() {
        let lock = EditLock(generatingLimit: .seconds(600))
        lock.move(to: .flushing, at: .seconds(0))
        lock.move(to: .waitingForModel, at: .seconds(1))
        // 900 s of waiting for the model: nothing is spent.
        #expect(lock.remaining(at: .seconds(900)) == .seconds(600))
        lock.move(to: .generating, at: .seconds(901))
        #expect(lock.remaining(at: .seconds(1001)) == .seconds(500))
        // Dictation takes the model: generating stops counting, however long it takes.
        lock.move(to: .waitingForModel, at: .seconds(1001))
        #expect(lock.remaining(at: .seconds(5000)) == .seconds(500))
        lock.move(to: .generating, at: .seconds(5000))
        #expect(lock.remaining(at: .seconds(5499)) == .seconds(1))
        #expect(lock.remaining(at: .seconds(5500)) == .zero)
        #expect(lock.remaining(at: .seconds(9000)) == .zero)
    }

    @Test func aNewRunStartsWithTheFullLimit() {
        let lock = EditLock(generatingLimit: .seconds(600))
        lock.move(to: .flushing, at: .zero)
        lock.move(to: .waitingForModel, at: .zero)
        lock.move(to: .generating, at: .zero)
        lock.move(to: .timedOut, at: .seconds(600))
        #expect(lock.remaining(at: .seconds(600)) == .zero)
        lock.move(to: .flushing, at: .seconds(700))
        #expect(lock.remaining(at: .seconds(700)) == .seconds(600))
    }

    @Test func resetTurnsAnEndIntoIdleAndLeavesActiveRunsAlone() {
        let ended = lock(at: .cancelled)
        ended.reset()
        #expect(ended.phase == .idle)
        let running = lock(at: .generating)
        running.reset()
        #expect(running.phase == .generating)
    }
}

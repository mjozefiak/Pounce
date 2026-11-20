import Foundation

/// One request at a time per provider, first in, first out (spec: `ProviderGate`). Priorities come with the second
/// consumer; in v1 the only one is background work.
public actor ProviderGate {
    public static let shared = ProviderGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var busy: Set<ProviderID> = []
    private var waiters: [ProviderID: [Waiter]] = [:]

    public init() {}

    /// Runs `body` when the provider is free. A cancelled task leaves the queue without running `body`.
    func withSlot<T: Sendable>(_ provider: ProviderID, _ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire(provider)
        defer { release(provider) }
        try Task.checkCancellation()
        return try await body()
    }

    var queuedCount: Int { waiters.values.reduce(0) { $0 + $1.count } }

    private func acquire(_ provider: ProviderID) async throws {
        try Task.checkCancellation()
        if !busy.contains(provider) {
            busy.insert(provider)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[provider, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(provider, id) }
        }
    }

    private func cancelWaiter(_ provider: ProviderID, _ id: UUID) {
        guard let index = waiters[provider]?.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters[provider]?.remove(at: index)
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func release(_ provider: ProviderID) {
        if var queue = waiters[provider], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[provider] = queue
            next.continuation.resume()  // the slot passes on; `busy` stays set
        } else {
            busy.remove(provider)
        }
    }
}

import Foundation

/// Keeps a live Spotlight query for application bundles (`kMDItemContentTypeTree ==
/// com.apple.application-bundle`) and publishes the paths it finds. It only supplements the directory
/// scan: when Spotlight is off or still indexing, the scan alone is complete enough.
@MainActor
final class AppMetadataWatcher {
    private var query: NSMetadataQuery?
    private var observers: [any NSObjectProtocol] = []
    private var continuation: AsyncStream<[String]>.Continuation?

    /// Starts the query; every gathering or update yields the full list of paths. Only the newest list
    /// is buffered, so a slow consumer never blocks the query.
    func start() -> AsyncStream<[String]> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: [String].self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemContentTypeTree == %@", "com.apple.application-bundle")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        self.query = query

        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(
                center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                }
            )
        }
        query.start()
        return stream
    }

    func stop() {
        query?.stop()
        query = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        continuation?.finish()
        continuation = nil
    }

    private func publish() {
        guard let query else { return }
        query.disableUpdates()
        var paths: [String] = []
        paths.reserveCapacity(query.resultCount)
        for index in 0..<query.resultCount {
            if let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            {
                paths.append(path)
            }
        }
        query.enableUpdates()
        continuation?.yield(paths)
    }
}

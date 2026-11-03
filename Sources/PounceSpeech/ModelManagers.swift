import Foundation
import Synchronization
import os

/// One `ModelManager` per directory. Two managers over the same folder would share a `<id>.partial` folder and
/// race on `removeItem` + `moveItem`, so every client (dictation, meetings, the settings panes) asks here.
public final class ModelManagers: Sendable {
    public static let shared = ModelManagers()

    public typealias Factory = @Sendable (URL, Logger) -> ModelManager

    private let factory: Factory
    private let managers = Mutex<[String: ModelManager]>([:])

    /// - Parameter factory: builds a manager for a directory; tests give it a fake downloader.
    public init(
        factory: @escaping Factory = { directory, logger in ModelManager(directory: directory, logger: logger) }
    ) {
        self.factory = factory
    }

    /// The manager of `directory`, created on first use. `logger` is used only by that first creation.
    public func manager(
        for directory: URL, logger: Logger = Logger(subsystem: "app.pounce", category: "speech")
    ) -> ModelManager {
        let key = directory.standardizedFileURL.path
        return managers.withLock { managers in
            if let existing = managers[key] { return existing }
            let created = factory(directory, logger)
            managers[key] = created
            return created
        }
    }
}

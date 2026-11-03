import Foundation
import os

/// Crash recovery of the notes (spec: Edge Cases): a meeting whose notes were `running` when the process died
/// would show "Writing notes" for ever. They become `failed` at open (any earlier text stays), so the library
/// offers "Regenerate" instead. Nothing is started again by itself: a model that crashed the app should not
/// be loaded in a loop. Called from `MeetingsLibrary.open()`, before anything can start a notes job.
enum NotesRecovery {
    @discardableResult
    static func run(store: MeetingsStore, logger: Logger) -> Int {
        do {
            let count = try store.failInterruptedNotes()
            if count > 0 { logger.notice("Notes interrupted by a crash: \(count, privacy: .public) marked failed") }
            return count
        } catch {
            logger.error("Notes recovery could not read the library")
            return 0
        }
    }
}

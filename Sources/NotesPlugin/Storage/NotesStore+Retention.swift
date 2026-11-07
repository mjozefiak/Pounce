import Foundation

/// The retention rules that run on store open and in each sweep (spec "Data Model", Retention): a `detached` row
/// without user writing and without an open comment (and not open in the registry) is deleted, and a `VACUUM`
/// follows at most once a day, only after something was deleted, as in Meetings and Dictation.
extension NotesStore {
    static let vacuumInterval: TimeInterval = 24 * 60 * 60

    /// Deletes the leftover detached rows and vacuums when one day has passed since the last `VACUUM`. A failed
    /// `VACUUM` never fails the deletion. Returns how many rows were deleted.
    @discardableResult
    func applyRetention(excluding openDocIDs: Set<Int64> = [], now: Date) throws -> Int {
        let deleted = try deleteUnkeptDetached(excluding: openDocIDs)
        if deleted > 0 { vacuumIfDue(now: now) }
        return deleted
    }

    /// `VACUUM` unless one ran less than a day ago. The time is taken before the call, so two callers never both
    /// vacuum, and given back when the `VACUUM` fails.
    @discardableResult
    func vacuumIfDue(now: Date) -> Bool {
        let previous: Date?? = lastVacuum.withLock { last in
            if let last, now.timeIntervalSince(last) < Self.vacuumInterval { return nil }
            let before = last
            last = now
            return .some(before)
        }
        guard let previous else { return false }
        do {
            try vacuum()
            return true
        } catch {
            lastVacuum.withLock { $0 = previous }
            return false
        }
    }
}

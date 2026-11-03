import Foundation

/// What the retention job needs from the spool (`Plugins/meetings/Spool/<uuid>/`, spec step 1.3). A stub
/// until the spool exists: `NoSpoolMaintenance` does nothing.
protocol SpoolMaintenance: Sendable {
    /// Removes the spool folders of deleted meetings. Returns how many existed.
    @discardableResult
    func removeSpools(forMeetings uuids: [String]) -> Int

    /// Removes spool folders last written before `cutoff` (`orphanAudioDays`: a meeting that stayed
    /// `incomplete` keeps only its transcript). Returns how many were removed.
    @discardableResult
    func removeSpools(olderThan cutoff: Date) -> Int
}

struct NoSpoolMaintenance: SpoolMaintenance {
    func removeSpools(forMeetings uuids: [String]) -> Int { 0 }
    func removeSpools(olderThan cutoff: Date) -> Int { 0 }
}

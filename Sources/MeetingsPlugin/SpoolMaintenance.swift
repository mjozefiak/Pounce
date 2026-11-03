import Foundation

/// What the retention job needs from the spool (`Plugins/meetings/Spool/<uuid>/`, spec step 1.3). A stub
/// until the spool exists: `NoSpoolMaintenance` does nothing.
protocol SpoolMaintenance: Sendable {
    /// Removes the spool folders of deleted meetings. Returns the uuids whose folder existed and was removed.
    @discardableResult
    func removeSpools(forMeetings uuids: [String]) -> [String]

    /// Removes, among the spool folders of `candidates`, those last written before `cutoff`
    /// (`orphanAudioDays`: a meeting that stayed `incomplete` keeps only its transcript). Folders of any other
    /// uuid are never touched: a meeting being recorded or processed owns its audio. Returns the uuids removed.
    ///
    /// Retention must not run before crash recovery (spec step 1.7) has had its chance to turn a leftover
    /// spool into an `incomplete` meeting; a spool without a row is not a candidate and stays.
    @discardableResult
    func removeSpools(olderThan cutoff: Date, among candidates: Set<String>) -> [String]
}

struct NoSpoolMaintenance: SpoolMaintenance {
    func removeSpools(forMeetings uuids: [String]) -> [String] { [] }
    func removeSpools(olderThan cutoff: Date, among candidates: Set<String>) -> [String] { [] }
}

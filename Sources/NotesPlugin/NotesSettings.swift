import Foundation
import LintelKit

/// `plugins.notes.*`: every key is declared here and nowhere else (a protected contract from the release that
/// ships Notes, `BACKWARD_COMPATIBILITY.md` section 3). There are no user-facing keys yet; the store step (4.0)
/// adds them.
enum NotesSettingsKey {
    #if DEBUG
    /// DEBUG only, set by `--qa-notes`: the Notes section lists fixture notes. Not a contract.
    static let qaFixtures = "qaFixtures"
    /// DEBUG only: note keys to open in tabs when the section is built, comma separated, each optionally with
    /// `@<layer id>` for the layer to show (`--qa-setting plugins.notes.qaOpen=meetings:<id>@transcript`).
    static let qaOpen = "qaOpen"
    #endif
}

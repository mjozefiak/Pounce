import Foundation
import LintelCore

extension PathText {
    /// Expands `~`, standardises the path and drops a trailing slash. Returns `nil` for a relative path.
    ///
    /// Kept out of `LintelCore`: `standardizingPath` drops a leading `/private` only when the shorter path
    /// exists, which it checks on disk.
    static func expand(_ text: String, home: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute: String
        if trimmed == "~" {
            absolute = home
        } else if trimmed.hasPrefix("~/") {
            absolute = home + trimmed.dropFirst()
        } else if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            return nil
        }
        let standardized = (absolute as NSString).standardizingPath
        return standardized.isEmpty ? nil : standardized
    }
}

import LintelKit
import SwiftUI

/// The "N things to do" title of a plugin's Settings banner (spec `2026-11-04-lintel-main-window`, steps 5.1 and
/// 5.2). The shell keeps the plugin's attention title and adds every denied readable permission the plugin needs
/// to the banner's detail (`StatusDerivation`), so the number counts those permissions too: it equals the number
/// of problems the banner lists.
public enum ThingsToDo {
    /// How many of `required` the shell will add to the banner: readable, denied, and not counted by the plugin
    /// already (a microphone macOS has not asked about is the plugin's own "Allow Microphone"). Reads only the
    /// permission states; asks for nothing and starts no work.
    @MainActor public static func deniedPermissions(
        _ required: Set<Permission>, countedByPlugin: Set<Permission> = [], reader: any PermissionsReader
    ) -> Int {
        required.filter { permission in
            permission.isReadable && !countedByPlugin.contains(permission)
                && reader.status(of: permission) == .denied
        }.count
    }

    /// The title for `count` things (at least one).
    public static func title(_ count: Int) -> LocalizedStringResource {
        switch count {
        case ...1:
            LocalizedStringResource(
                "1 thing to do", comment: "Settings banner: one thing is needed before the feature works")
        case 2:
            LocalizedStringResource(
                "2 things to do", comment: "Settings banner: two things are needed before the feature works")
        default:
            LocalizedStringResource(
                "\(count) things to do",
                comment: "Settings banner: the number of things needed (Permissions pane and plugin panes)")
        }
    }
}

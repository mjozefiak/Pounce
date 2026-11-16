import CoreGraphics
import Foundation
import LintelKit

// Optional capabilities of a layout kind. Each is its own small protocol; a strategy that has one returns itself from
// the matching accessor of `LayoutStrategy` (`library`, `snapping`, `settingRows`), so a kind that does not has no
// stub to write and the callers need no dynamic cast.

/// The kind assigns layouts from the layout library (stock templates and the user's): the Layouts window's matrix is
/// active for its workspaces, the layout slots and *Next zone layout* apply to them. The library and its window are
/// the Zones feature (`GridLayout`); another kind may join it by providing the layout it shows.
protocol LayoutLibraryProviding: Sendable {
    /// The id of the library layout the workspace shows on a display. *Next zone layout* steps from it.
    func libraryLayoutID(
        _ environment: LayoutEnvironment, workspace: WorkspaceID, displayKey: String, orientation: DisplayOrientation
    ) -> String
}

/// The kind offers snap targets: dragging a window over the overlay's zones snaps it. The strategy decides what a
/// snap means by giving every target the command to send (`DragZone.command`); the plugin sends it for the dragged
/// window without knowing the kind.
protocol SnapTargetProviding: Sendable {
    /// The slots the snap overlay offers for the workspace, empty when it has none.
    func snapTargets(_ input: LayoutInput) -> [DragDisplay]
}

/// What a strategy may use to build its settings rows: the settings, the layouts of the library and a way to tell the
/// plugin that a setting changed. Not the pane model.
struct LayoutSettingsContext {
    var settings: WindowsSettings
    var layouts: @MainActor () -> [GridLayout]
    var apply: @MainActor () -> Void
}

/// A row a strategy adds to Settings → Window Management → Basics for its own settings that are not options (for
/// Zones: the default layout of each display shape). The pane draws it, the strategy decides what it means.
struct LayoutSettingRow: Identifiable {
    struct Choice: Hashable {
        var id: String
        var title: String
    }

    var id: String
    var title: String
    var help: String?
    /// Read when the pane is drawn, so a library that changed shows its layouts.
    var choices: @MainActor () -> [Choice]
    var selection: @MainActor () -> String
    var select: @MainActor (String) -> Void
}

@MainActor
protocol SettingRowProviding {
    func settingRows(_ context: LayoutSettingsContext) -> [LayoutSettingRow]
}

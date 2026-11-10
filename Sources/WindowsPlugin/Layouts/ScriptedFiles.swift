#if DEBUG
import Foundation
import Synchronization

/// DEBUG only (QA): files and the app picker answered from values the QA command route sets, so no open or save panel
/// ever opens in a QA run (the panels write their sizes and the Go To sheet's frame into the real defaults domain, and
/// synthetic keys cannot drive them). The release build always uses the real panels.
@MainActor
final class ScriptedFiles: LayoutFileAccess {
    var importURL: URL?
    var exportURL: URL?
    /// The app the next "Add App…" picks; read from the pane model's closure, so it is not main-actor state.
    nonisolated let appPicker = AppPicker()

    final class AppPicker: Sendable {
        private let value = Mutex<String?>(nil)
        func set(_ bundleID: String?) { value.withLock { $0 = bundleID } }
        func take() -> String? {
            value.withLock { current in
                defer { current = nil }
                return current
            }
        }
    }

    func chooseImport() -> URL? {
        defer { importURL = nil }
        return importURL
    }

    func chooseExport(suggestedName: String) -> URL? {
        defer { exportURL = nil }
        return exportURL
    }

}
#endif

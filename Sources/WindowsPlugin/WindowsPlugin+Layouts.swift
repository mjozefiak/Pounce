import AppKit
import Foundation
import LintelKit
import SwiftUI

/// The Layouts window, the grid editor and the `.lintellayouts` file the user opens.
extension WindowsPlugin {
    func makeLayoutsWindow() -> LayoutsWindowController {
        let settings = settings
        return LayoutsWindowController(
            makeModel: { [weak self] in
            guard let self else { return nil }
            return LayoutsModel(
                pane: paneModel, displays: { [client = context.windows] in await client.displays() },
                identify: { [identifier] display in identifier.show(display) },
                openEditor: { [weak self] layout, isNew, onSaved in
                    guard let self else { return }
                    openEditor(layout: layout, isNew: isNew, parent: layoutsWindow.window, onSaved: onSaved)
                },
                files: AppKitLayoutFiles())
            },
            loadFrame: { settings.layoutsWindowFrame }, saveFrame: { settings.setLayoutsWindowFrame($0) })
    }

    /// Opens the grid editor on a layout (a copy of a stock one, a user's own, or a new one). Needs the running
    /// plugin: the library lives in its runtime.
    func openEditor(
        layout: GridLayout, isNew: Bool, parent: NSWindow? = nil, onSaved: @escaping (GridLayout) -> Void = { _ in }
    ) {
        guard let repository = runtime?.layouts else { return }
        editorWindow.show(parent: parent) { [client = context.windows] preview, close in
            GridEditorModel(
                layout: layout, isNew: isNew, repository: repository, displays: { await client.displays() },
                preview: preview,
                announce: { text in
                    AccessibilityNotification.Announcement(text).post()
                },
                onSaved: onSaved,
                onClose: { [weak self] in
                    close()
                    // The plugin was switched off while the editor held changes: the Layouts window was left
                    // open for the editor's sheet and goes with it.
                    if let self, runtime == nil { layoutsWindow.close() }
                })
        }
    }

    /// A double-clicked `.lintellayouts` file: the Layouts window opens and shows what importing it would do
    /// (never adds anything by itself). A plugin that is off only says so.
    public func handleOpenedFile(_ url: URL) async -> Bool {
        guard url.pathExtension.lowercased() == LayoutFileType.fileExtension else { return false }
        layoutsWindow.show()
        guard let model = layoutsWindow.model else { return true }
        await model.refresh()
        model.loadImport(from: url)
        return true
    }
}

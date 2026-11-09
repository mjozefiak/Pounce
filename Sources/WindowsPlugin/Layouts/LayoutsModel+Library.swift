import AppKit
import Foundation
import LintelUI
import UniformTypeIdentifiers

/// The `.lintellayouts` file type (declared in `Info.plist`, step 4.4).
enum LayoutFileType {
    static let fileExtension = "lintellayouts"
    static let identifier = "com.lintelapp.layouts"

    static var contentTypes: [UTType] {
        [UTType(identifier), UTType(filenameExtension: fileExtension), .json].compactMap { $0 }
    }
}

/// Where the Layouts window gets and puts files: the open and save panels in the app, a fake in tests.
@MainActor
protocol LayoutFileAccess {
    func chooseImport() -> URL?
    func chooseExport(suggestedName: String) -> URL?
}

struct NoLayoutFiles: LayoutFileAccess {
    func chooseImport() -> URL? { nil }
    func chooseExport(suggestedName: String) -> URL? { nil }
}

struct AppKitLayoutFiles: LayoutFileAccess {
    func chooseImport() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = LayoutFileType.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(
            localized: "Choose a layouts file to import.", comment: "Layouts window: the open panel's message")
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseExport(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(LayoutFileType.identifier) ?? .json]
        panel.nameFieldStringValue = suggestedName + "." + LayoutFileType.fileExtension
        panel.message = String(
            localized: "Export layouts to a file you can share.", comment: "Layouts window: the save panel's message")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// What deleting a layout would change: the cells that use it fall back to the display default.
struct LayoutDeletion: Equatable {
    var layoutID: String
    var name: String
    var cells: [(workspace: WorkspaceID, displayKey: String)]
    /// "Workspace 1 on Main display", at most six, then "and N more".
    var cellNames: [String]

    static func == (lhs: LayoutDeletion, rhs: LayoutDeletion) -> Bool {
        lhs.layoutID == rhs.layoutID && lhs.name == rhs.name && lhs.cellNames == rhs.cellNames
            && lhs.cells.map { "\($0.workspace.rawValue)|\($0.displayKey)" }
                == rhs.cells.map { "\($0.workspace.rawValue)|\($0.displayKey)" }
    }

    var confirmation: DestructiveConfirmation {
        let detail = LocalizedStringResource(
            "This can’t be undone.", comment: "Confirmation sheet: the consequence line of a destructive action")
        let confirm = LocalizedStringResource("Delete", comment: "Layouts window: deletes the selected layout")
        if cells.isEmpty {
            return DestructiveConfirmation(
                prompt: LocalizedStringResource(
                    "Delete “\(name)”? No workspace uses it.",
                    comment: "Layouts window: asked before a layout nobody uses is deleted"),
                detail: detail, confirmTitle: confirm)
        }
        let list = cellNames.joined(separator: ", ")
        return DestructiveConfirmation(
            prompt: LocalizedStringResource(
                "Delete “\(name)”? Assignments that will use the default layout instead: \(cells.count) (\(list)).",
                comment: "Layouts window: asked before a layout in use is deleted; the count and the cells"),
            detail: detail, confirmTitle: confirm)
    }
}

extension LayoutsModel {
    // MARK: Reading

    var canEditLibrary: Bool { isActive && !libraryLocked }

    func isStock(_ layout: GridLayout) -> Bool { StockLayouts.isStock(layout.id) }

    var canEditSelected: Bool { canEditLibrary && !isStock(selectedLayout) }

    /// The slots a layout is bound to, in order.
    func slots(of layoutID: String) -> [Int] { slots.filter { $0.value == layoutID }.keys.sorted() }

    func refreshLibrary() async {
        await pane.reloadLibrary()
        if let runtime = pane.runtime() {
            let snapshot = await runtime.layouts.snapshot
            userLayouts = snapshot.user
            slots = snapshot.slots
            libraryLocked = snapshot.isReadOnly
            keptUntouched = await runtime.layouts.keptUntouchedCount
        } else {
            userLayouts = []
            slots = [:]
            libraryLocked = false
            keptUntouched = 0
        }
        if library.layout(selectedLayoutID) == nil { selectedLayoutID = StockLayouts.columns2 }
    }

    // MARK: Creating and editing

    /// A layout for *New layout*: one zone, named with the default name (user data from then on).
    static func newDraft() -> GridLayout {
        GridLayout(
            id: "",
            name: String(localized: "New layout", comment: "Layout editor: the title while a layout is being made"),
            spacing: 8, columns: [1], rows: [1],
            zones: [GridZone(id: 1, colStart: 0, colEnd: 1, rowStart: 0, rowEnd: 1)])
    }

    func newLayout() {
        guard canEditLibrary else { return }
        openEditor(Self.newDraft(), true) { [weak self] saved in self?.libraryChanged(select: saved.id) }
    }

    func editSelected() {
        guard canEditSelected else { return }
        openEditor(selectedLayout, false) { [weak self] saved in self?.libraryChanged(select: saved.id) }
    }

    private func libraryChanged(select id: String) {
        Task {
            await refreshLibrary()
            selectedLayoutID = id
            await pane.runtime()?.applySettings()
            pane.runtime()?.context.resultsChanged()
        }
    }

    // MARK: Library actions

    private func run(_ body: (LayoutRepository) async throws -> String?) async {
        guard canEditLibrary, let repository = pane.runtime()?.layouts else { return }
        notice = nil
        do {
            if let id = try await body(repository) { selectedLayoutID = id }
        } catch let error as LayoutRepository.RepositoryError {
            notice = Self.text(for: error)
        } catch {
            notice = Self.text(for: .write)
        }
        await refreshLibrary()
        await pane.runtime()?.applySettings()
        pane.runtime()?.context.resultsChanged()
    }

    static func text(for error: LayoutRepository.RepositoryError) -> String {
        switch error {
        case .readOnly:
            String(
                localized: "These layouts were saved by a newer version of Lintel and can’t be changed here.",
                comment: "Layout editor: saving is refused because the library file is newer")
        case .write:
            String(
                localized: "The layout could not be saved. Your other layouts are unchanged.",
                comment: "Layout editor: the file could not be written")
        case .limit:
            String(
                localized: "The library is full: 256 layouts is the most it can hold.",
                comment: "Layouts window: the library has the most layouts it can hold")
        case .stock, .notFound, .invalid:
            String(
                localized: "This layout can’t be saved. Check the name and the zones.",
                comment: "Layout editor: the layout breaks a rule")
        }
    }

    func duplicateSelected() async {
        let source = selectedLayout
        let name = String(
            localized: "\(StockLayouts.displayName(of: source)) copy",
            comment: "Layouts window: the default name of a duplicated layout; the original's name first")
        // Cap the name so a long original never makes the copy invalid.
        let capped = String(name.prefix(LayoutRules.maximumNameLength))
        await run { try await $0.duplicate(source.id, name: capped).id }
    }

    func renameSelected(to name: String) async {
        guard canEditSelected else { return }
        let id = selectedLayoutID
        isRenaming = false
        await run {
            try await $0.rename(id, to: name)
            return nil
        }
    }

    // MARK: Delete

    func requestDelete() {
        guard canEditSelected else { return }
        let layout = selectedLayout
        let cells = table.entries.filter { $0.layoutID == layout.id }.sorted {
            ($0.workspace.rawValue, $0.displayKey) < ($1.workspace.rawValue, $1.displayKey)
        }
        var names = cells.prefix(6).map { cellName(workspace: $0.workspace, displayKey: $0.displayKey) }
        if cells.count > 6 {
            names.append(
                String(
                    localized: "and \(cells.count - 6) more",
                    comment: "Layouts window: the delete question lists six cells and then how many more"))
        }
        pendingDelete = LayoutDeletion(
            layoutID: layout.id, name: layout.name, cells: cells.map { ($0.workspace, $0.displayKey) }, cellNames: names
        )
    }

    func confirmDelete() async {
        guard let deletion = pendingDelete, let runtime = pane.runtime() else { return }
        pendingDelete = nil
        await run {
            _ = try await $0.delete(deletion.layoutID, assignments: runtime.assignments)
            return nil
        }
        selectedLayoutID = StockLayouts.columns2
        table = await runtime.assignments.table
    }

    /// "Workspace 1 on Main display": a cell in words, without the display's key.
    func cellName(workspace: WorkspaceID, displayKey: String) -> String {
        let place: String
        if let display = displays.first(where: { $0.key == displayKey }) {
            place = display.title
        } else if displayKey == DisplayKeys.landscape {
            place = String(
                localized: "every landscape display", comment: "Layouts window: a cell chosen for a display shape")
        } else if displayKey == DisplayKeys.portrait {
            place = String(
                localized: "every portrait display", comment: "Layouts window: a cell chosen for a display shape")
        } else {
            place = String(
                localized: "a display that is not connected",
                comment: "Layouts window: a cell of a display that is not here now")
        }
        return String(
            localized: "Workspace \(workspace.rawValue) on \(place)",
            comment: "Layouts window: a cell, by workspace and display")
    }

    // MARK: Import and export

    func beginImport() {
        guard canEditLibrary, let url = files.chooseImport() else { return }
        loadImport(from: url)
    }

    /// Reads a file and shows what importing it would do. Also the entry for a double-clicked file.
    func loadImport(from url: URL) {
        notice = nil
        guard canEditLibrary else {
            notice = String(
                localized: "Turn Window Management on to import layouts.",
                comment: "Layouts window: an import needs the plugin to be running")
            return
        }
        guard let data = Self.readLimited(url) else {
            notice = String(
                localized: "That file could not be read.",
                comment: "Layouts window: an import file is missing, a folder, or not readable")
            return
        }
        do {
            let preview = try LayoutImporter.inspect(
                data, existingIDs: Set(userLayouts.map(\.id)),
                // Layouts kept untouched count toward the 256 too, so the summary matches what adding accepts.
                existingCount: userLayouts.count + keptUntouched)
            pendingImport = preview
        } catch {
            notice = Self.text(for: error)
        }
    }

    /// At most the size limit plus one byte, so an enormous file is never read whole; `nil` when the file cannot
    /// be read at all (missing, a folder, no permission), which is not the same as too large.
    static func readLimited(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: LayoutRules.maximumFileSize + 1) else { return nil }
        return data
    }

    static func text(for error: ImportError) -> String {
        switch error {
        case .tooLarge:
            String(
                localized: "That file is too large to be a layouts file (1 MB at most).",
                comment: "Layouts window: an import file is over the size limit")
        case .malformed:
            String(
                localized: "That file is not a Lintel layouts file.",
                comment: "Layouts window: an import file cannot be read")
        case .tooManyLayouts:
            String(
                localized: "That file has too many layouts. A library holds 256 at most.",
                comment: "Layouts window: an import would exceed the layout limit")
        case .newerVersion:
            String(
                localized: "That file was made by a newer version of Lintel.",
                comment: "Layouts window: an import file has a newer format")
        }
    }

    func cancelImport() { pendingImport = nil }

    func confirmImport() async {
        guard let preview = pendingImport else { return }
        pendingImport = nil
        let added = preview.layouts
        await run { repository in
            try await repository.add(added).last?.id
        }
        if notice == nil {
            notice = String(
                localized: "Imported \(added.count) layouts.", comment: "Layouts window: what an import added")
        }
    }

    /// The lines of the import summary (shown before anything is added).
    func importLines(_ preview: ImportPreview) -> [String] {
        var lines = [
            String(
                localized: "\(preview.layouts.count) layouts will be added.",
                comment: "Layouts window: the import summary, how many layouts are added")
        ]
        if preview.regeneratedIDs > 0 {
            lines.append(
                String(
                    localized: "\(preview.regeneratedIDs) get a new identity because theirs is already used.",
                    comment: "Layouts window: the import summary, layouts whose ids collided"))
        }
        if preview.skippedUnknownStyle > 0 {
            lines.append(
                String(
                    localized: "\(preview.skippedUnknownStyle) skipped: a style this version doesn’t know.",
                    comment: "Layouts window: the import summary, layouts of another style"))
        }
        if preview.rejected > 0 {
            lines.append(
                String(
                    localized: "\(preview.rejected) skipped: they break a rule.",
                    comment: "Layouts window: the import summary, invalid layouts"))
        }
        lines.append(
            String(
                localized: "Assignments and layout slots are never imported.",
                comment: "Layouts window: the import summary, what a file cannot change"))
        return lines
    }

    enum ExportScope { case selected, allMine }

    /// Writes the layouts to a file the user chooses. Names go in as shown.
    func export(_ scope: ExportScope) {
        notice = nil
        let layouts: [GridLayout]
        let suggested: String
        switch scope {
        case .selected:
            var layout = selectedLayout
            layout.name = StockLayouts.displayName(of: layout)
            layouts = [layout]
            suggested = layout.name
        case .allMine:
            layouts = userLayouts
            suggested = String(localized: "My layouts", comment: "Layouts window: the default file name of an export")
        }
        guard !layouts.isEmpty, let url = files.chooseExport(suggestedName: suggested) else { return }
        do {
            try LayoutExporter.data(for: layouts).write(to: url, options: .atomic)
            notice = String(
                localized: "Exported \(layouts.count) layouts.", comment: "Layouts window: what an export wrote")
        } catch {
            notice = String(
                localized: "The file could not be written.", comment: "Layouts window: an export failed")
        }
    }

    // MARK: Slots

    func setSlot(_ number: Int, to layoutID: String?) async {
        guard canEditLibrary, let repository = pane.runtime()?.layouts else { return }
        notice = nil
        do {
            try await repository.setSlot(number, to: layoutID)
        } catch {
            notice = Self.text(for: .write)
        }
        await refreshLibrary()
    }
}

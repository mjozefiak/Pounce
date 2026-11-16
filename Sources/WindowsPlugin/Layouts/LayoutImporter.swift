import Foundation

/// What an import file holds, worked out before anything is added (spec: Data Model, "shows a summary before it
/// adds anything").
struct ImportPreview: Equatable, Sendable {
    /// The layouts that would be added, with the ids they would get.
    var layouts: [GridLayout]
    /// How many ids were replaced because they collided with a layout that exists.
    var regeneratedIDs: Int
    /// Layouts of a style this build cannot use (for example `canvas`): not imported.
    var skippedUnknownStyle: Int
    /// Layouts that break a rule: not imported.
    var rejected: Int

    var isEmpty: Bool { layouts.isEmpty }
}

enum ImportError: Error, Equatable, Sendable {
    /// More than 1 MB.
    case tooLarge
    /// Not a layouts file, or numbers or text the validator refuses.
    case malformed
    /// More than 256 layouts in the file, or in the library after the import.
    case tooManyLayouts
    /// The file comes from a newer version of Lintel.
    case newerVersion
}

/// Reads a `.lintellayouts` file (spec: Data Model). It goes through `LayoutDocument.parse`, the parser and
/// validator of `layouts.json`, so import is not a second code path. Layouts only: assignments and layout slots
/// in a file are ignored, never imported.
enum LayoutImporter {
    static func inspect(
        _ data: Data, existingIDs: Set<String>, existingCount: Int = 0
    ) throws(ImportError) -> ImportPreview {
        let document: LayoutDocument
        do {
            document = try LayoutDocument.parse(data, enforceFileLimits: true, lenientIDs: true)
        } catch {
            switch error {
            case .tooLarge: throw .tooLarge
            case .tooManyLayouts: throw .tooManyLayouts
            case .malformed: throw .malformed
            }
        }
        guard document.version <= LayoutRules.currentVersion else { throw .newerVersion }
        var taken = existingIDs.union(StockLayouts.all.map(\.id))
        var preview = ImportPreview(layouts: [], regeneratedIDs: 0, skippedUnknownStyle: 0, rejected: 0)
        for entry in document.entries {
            switch entry {
            case .grid(var layout):
                if !LayoutRules.isValidUserID(layout.id) || taken.contains(layout.id) {
                    layout.id = freshID(avoiding: taken)
                    preview.regeneratedIDs += 1
                }
                layout.name = layout.name.trimmingCharacters(in: .whitespacesAndNewlines)
                taken.insert(layout.id)
                preview.layouts.append(layout)
            case .opaque(let opaque):
                switch opaque.reason {
                case .unknownStyle: preview.skippedUnknownStyle += 1
                case .invalid: preview.rejected += 1
                }
            }
        }
        guard existingCount + preview.layouts.count <= LayoutRules.maximumLayouts else { throw .tooManyLayouts }
        return preview
    }

    private static func freshID(avoiding taken: Set<String>) -> String {
        var id: String
        repeat { id = LayoutRules.userIDPrefix + UUID().uuidString.lowercased() } while taken.contains(id)
        return id
    }
}

/// Writes layouts for sharing: version and layouts only (no assignments, no slots).
enum LayoutExporter {
    /// `.lintellayouts`: the file's bytes. A stock template gets a fresh user id, because the stock ids belong to
    /// the app; names are written as they are shown.
    static func data(for layouts: [GridLayout]) throws -> Data {
        let entries: [LayoutEntry] = layouts.map {
            var layout = $0
            if StockLayouts.isStock(layout.id) { layout.id = LayoutRules.userIDPrefix + UUID().uuidString.lowercased() }
            return .grid(layout)
        }
        return try LayoutDocument(version: LayoutRules.currentVersion, entries: entries, slots: [:]).encoded()
    }
}

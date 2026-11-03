import PounceKit
import SwiftUI

/// The library list mode (spec step 1.11): `meetings.library`, without a default shortcut.
extension MeetingsPlugin {
    static let libraryCommandID = "meetings.library"
    static let libraryModeID: PanelModeID = "meetings.library"

    var libraryCommand: PluginCommand {
        PluginCommand(
            id: Self.libraryCommandID,
            title: LocalizedStringResource(
                "Meeting Library", comment: "Menu item and command that opens the list of meetings"),
            symbolName: "person.2.wave.2",
            panelMode: Self.libraryModeID)
    }

    public var panelModes: [PanelMode] {
        let library = library
        let source = MeetingsLibrarySource(store: { library.store }, actions: libraryActions)
        return [
            PanelMode(
                id: Self.libraryModeID,
                title: LocalizedStringResource(
                    "Meeting Library", comment: "Menu item and command that opens the list of meetings"),
                symbolName: "person.2.wave.2",
                source: source,
                filters: [
                    PanelModeFilter(
                        id: MeetingLibraryFilter.all.rawValue,
                        title: LocalizedStringResource("All", comment: "Meeting library filter"),
                        symbolName: "list.bullet"),
                    PanelModeFilter(
                        id: MeetingLibraryFilter.withNotes.rawValue,
                        title: LocalizedStringResource("With Notes", comment: "Meeting library filter"),
                        symbolName: "doc.text"),
                    PanelModeFilter(
                        id: MeetingLibraryFilter.needsAttention.rawValue,
                        title: LocalizedStringResource("Needs Attention", comment: "Meeting library filter"),
                        symbolName: "exclamationmark.triangle"),
                ],
                makeStatus: { AnyView(MeetingLibraryStatusView(library: library)) },
                makePreview: { candidate in
                    AnyView(
                        MeetingLibraryPreview(
                            id: MeetingLibraryPresentation.meetingID(candidate.itemKey),
                            load: { id in await Self.previewContent(of: id, library: library) }))
                },
                makeEmptyView: { AnyView(MeetingLibraryEmptyView(library: library)) })
        ]
    }

    /// Reads the meeting off the main actor; `nil` when it is gone or the library is not open.
    private static func previewContent(of id: Int64, library: MeetingsLibrary) async -> MeetingPreviewContent? {
        guard let store = library.store else { return nil }
        return await Task.detached { () -> MeetingPreviewContent? in
            guard let document = try? store.loadDocument(id: id) else { return nil }
            return MeetingPreviewBuilder.build(document)
        }.value
    }
}

import LintelKit
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
        let source = MeetingsLibrarySource(
            store: { library.store }, actions: libraryActions, notes: notes.board, openSettings: context.openSettings)
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
                            refreshToken: "\(candidate.badge ?? "")|\(candidate.subtitle ?? "")",
                            load: { id in await Self.previewContent(of: id, library: library) }))
                },
                makeEmptyView: { AnyView(MeetingLibraryEmptyView(library: library)) })
        ]
    }

    /// Reads the meeting off the main actor and stops when the selection moves on.
    static func previewContent(of id: Int64, library: MeetingsLibrary) async -> MeetingPreviewLoad {
        guard let store = library.store else { return .missing }
        do {
            guard let document = try await MeetingLibraryIO.document(store: store, id: id) else { return .missing }
            return .content(MeetingPreviewBuilder.build(document))
        } catch is CancellationError {
            return .missing
        } catch {
            return .failed
        }
    }
}

import LintelKit
import LintelUI
import SwiftUI

/// History (prototype `lib-history`, `.ip` with `.he` rows): who changed the text, when, what, and Compare and
/// Restore on the entries that allow them. The list belongs to the layer on screen.
struct NoteHistoryPane: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch document.history {
            case .idle, .loading:
                Text("Loading history…", comment: "Inspector, History: while the versions are read")
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.secondaryText)
            case .none:
                note(
                    Text(
                        "Nothing has been changed here yet. Edits by you and by the agent are listed here, with who made them.",
                        comment: "Inspector, History: the layer has no edits"))
            case .failed:
                note(
                    Text(
                        "History can’t be read right now. Nothing was changed.",
                        comment: "Inspector, History: notes.sqlite could not be read"))
            case .loaded(let snapshot):
                ForEach(snapshot.entries) { entry in
                    NoteHistoryRow(
                        model: model, entry: entry, layer: snapshot.layer,
                        canRestore: model.canRestore(document, snapshot))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("History", comment: "Accessibility label of the version history list"))
    }

    private func note(_ text: Text) -> some View {
        text
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The footer under the list (prototype `.ipb`, `.hp2`).
struct NoteHistoryFooter: View {
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Text(
            "History stays on this Mac, encrypted, as long as the note.",
            comment: "Inspector, History: where the versions are kept"
        )
        .font(textSize.font(.footnote))
        .foregroundStyle(LintelBrand.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { LintelDivider() }
    }
}

struct NoteHistoryRow: View {
    let model: NotesWorkspaceModel
    let entry: HistoryEntry
    let layer: String
    let canRestore: Bool
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(entry.author.barColor)
                .frame(width: 0.7 * 12.5 * textSize.scale, height: 0.7 * 12.5 * textSize.scale)
                .padding(.top, 0.45 * 12.5 * textSize.scale)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text(verbatim: entry.author.gutterText)
                        .font(textSize.font(.footnote, weight: .semibold).monospaced())
                        .foregroundStyle(LintelBrand.ink)
                    Text(
                        verbatim: " · \(model.presentation.historyTime(entry.createdAt, now: model.environment.now()))"
                    )
                    .font(textSize.font(.footnote))
                    .foregroundStyle(LintelBrand.secondaryText)
                }
                Text(verbatim: entry.change.text(layer: layer, author: entry.author))
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if entry.canCompare {
                        link(Text("Compare", comment: "Inspector, History: shows what a version changed")) {
                            Task { await model.showCompare(revisionID: entry.id) }
                        }
                    }
                    if entry.canRestore && canRestore {
                        link(Text("Restore", comment: "Inspector, History: makes an earlier version the text again")) {
                            Task { await model.restore(revisionID: entry.id) }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    private func link(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .font(textSize.font(.footnote, weight: .semibold))
                .foregroundStyle(LintelBrand.accentText)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}

extension HistoryEntry.Change {
    /// What the entry says in words: counts of blocks, never the text of one.
    func text(layer: String, author: NoteAuthor) -> String {
        switch self {
        case .original:
            switch author {
            case .agent:
                layer == "cleaned"
                    ? String(
                        localized: "Cleaned up the text",
                        comment: "Inspector, History: first version by the agent, dictation")
                    : String(localized: "Wrote the notes", comment: "Inspector, History: first version by the agent")
            case .human:
                String(localized: "Started the note", comment: "Inspector, History: first version of a manual note")
            default:
                String(
                    localized: "Text as recorded", comment: "Inspector, History: first version, from speech recognition"
                )
            }
        case .restored:
            String(localized: "Restored an earlier version", comment: "Inspector, History: a Restore")
        case .proposed:
            String(
                localized: "Kept as a proposal, not applied",
                comment: "Inspector, History: a version that was set aside instead of replacing the text")
        case .unchanged:
            String(localized: "No change in the text", comment: "Inspector, History: a version equal to the one before")
        case .blocks(let edited, let added, let removed):
            [
                edited > 0
                    ? String(
                        localized: "Edited \(edited) blocks", comment: "Inspector, History: how many blocks changed")
                    : nil,
                added > 0
                    ? String(
                        localized: "Added \(added) blocks", comment: "Inspector, History: how many blocks were added")
                    : nil,
                removed > 0
                    ? String(
                        localized: "Removed \(removed) blocks", comment: "Inspector, History: how many blocks went")
                    : nil,
            ].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

import LintelKit
import LintelUI
import SwiftUI

/// A strip under the path bar (prototype `.strip`): a dot in the tone's colour, the sentence, the actions as
/// accent links. The words carry the meaning; the dot only repeats it.
struct NoteStripView: View {
    let strip: NotesWorkspaceModel.Strip
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(dot).frame(width: 7 * textSize.scale, height: 7 * textSize.scale)
                    .accessibilityHidden(true)
                Text(verbatim: strip.text)
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                ForEach(strip.actions) { action in
                    Button {
                        Task { await model.perform(action.id) }
                    } label: {
                        Text(verbatim: action.title)
                            .font(textSize.font(.callout, weight: .semibold))
                            .foregroundStyle(LintelBrand.accentText)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                if strip.isDismissible {
                    Button {
                        model.dismissStrip(strip.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(textSize.font(.caption2, weight: .semibold))
                            .foregroundStyle(LintelBrand.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Dismiss", comment: "Accessibility label of a strip's close button"))
                }
            }
            .padding(.horizontal, 16 * textSize.scale)
            .padding(.vertical, 4 * textSize.scale)
            .frame(minHeight: 28.75 * textSize.scale)
            .background(background)
            LintelDivider()
        }
        .accessibilityElement(children: .contain)
    }

    private var dot: Color {
        switch strip.tone {
        case .accent: LintelBrand.accent
        case .attention: LintelBrand.statusAttention
        case .error: LintelBrand.statusError
        }
    }

    private var background: Color {
        switch strip.tone {
        case .accent: LintelBrand.windowSelectionTint
        case .attention: LintelBrand.statusAttention.opacity(0.11)
        case .error: LintelBrand.statusError.opacity(0.11)
        }
    }
}

/// The empty states of the centre column (prototype `.emp`): the symbol, a title, a line and optional rows.
struct NoteEmptyState<Rows: View>: View {
    let symbol: String
    let title: Text
    let message: Text
    @ViewBuilder var rows: Rows
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 40 * textSize.scale))
                .foregroundStyle(LintelBrand.ink.opacity(0.9))
                .padding(.bottom, 12 * textSize.scale)
                .accessibilityHidden(true)
            title
                .font(textSize.font(.title3, weight: .semibold))
                .foregroundStyle(LintelBrand.ink)
                .multilineTextAlignment(.center)
            message
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 4 * textSize.scale)
                .padding(.bottom, 14 * textSize.scale)
            rows
        }
        .frame(maxWidth: 26 * 12.5 * textSize.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A shortcut hint row of an empty state (prototype `.sr span`): the name and the keys.
struct NoteShortcutRow: View {
    let title: Text
    let keys: String
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack {
            title
            Spacer(minLength: 16)
            Text(verbatim: keys)
                .font(textSize.font(.caption1, weight: .semibold))
                .padding(.horizontal, 6)
                .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 5))
        }
        .font(textSize.font(.callout))
        .foregroundStyle(LintelBrand.secondaryText)
        .frame(width: 19 * 12.5 * textSize.scale)
        .padding(.vertical, 3 * textSize.scale)
        .accessibilityElement(children: .combine)
    }
}

/// What the centre column shows when no note is open and the section has something to say.
struct NoteScreenView: View {
    let model: NotesWorkspaceModel
    let screen: NotesWorkspaceModel.Screen
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        switch screen {
        case .loading:
            NoteSkeletonDocument()
        case .locked:
            NoteEmptyState(
                symbol: "lock",
                title: Text(
                    "Lintel can’t read the key to your notes", comment: "Notes: title when the notes key is missing"),
                message: Text(
                    "Nothing was deleted. Unlock your login keychain and try again.",
                    comment: "Notes: what to do when the notes key is missing")
            ) {
                Button {
                    Task { await model.perform("locked.retry") }
                } label: {
                    Text("Try again", comment: "Notes: strip action that tries the failed step again")
                        .font(textSize.font(.callout, weight: .semibold))
                        .foregroundStyle(LintelBrand.accentText)
                }
                .buttonStyle(.plain)
            }
        case .empty(let off):
            if off {
                NoteEmptyState(
                    symbol: "note.text",
                    title: Text(
                        "Write a note, or turn on recording", comment: "Notes: empty library, recording is off"),
                    message: Text(
                        "Notes work without recording. Meetings and Dictation add recorded notes.",
                        comment: "Notes: what recording adds to the notes")
                ) {
                    NoteShortcutRow(title: Text("New note", comment: "Notes: shortcut hint"), keys: "⌘N")
                    NoteShortcutRow(title: Text("Go to a note", comment: "Notes: shortcut hint"), keys: "⌘P")
                    Button(action: model.openSettings) {
                        Text("Turn on recording in Settings…", comment: "Notes: opens Settings to switch recording on")
                            .font(textSize.font(.callout, weight: .semibold))
                            .foregroundStyle(LintelBrand.accentText)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 3 * textSize.scale)
                }
            } else {
                NoteEmptyState(
                    symbol: "note.text",
                    title: Text("Your notes will appear here", comment: "Notes: empty library"),
                    message: Text(
                        "Meeting notes and dictations are kept on this Mac.",
                        comment: "Notes: empty library, where they live")
                ) {
                    NoteShortcutRow(title: Text("New note", comment: "Notes: shortcut hint"), keys: "⌘N")
                    NoteShortcutRow(title: Text("Record a meeting", comment: "Notes: shortcut hint"), keys: "⌃⌥M")
                    NoteShortcutRow(title: Text("Dictate", comment: "Notes: shortcut hint"), keys: "⌃⌥D")
                    NoteShortcutRow(title: Text("Go to a note", comment: "Notes: shortcut hint"), keys: "⌘P")
                }
            }
        case .noResults, .list:
            NoteEmptyState(
                symbol: "note.text",
                title: Text("Select a note", comment: "Notes: centre column when no tab is open"),
                message: Text(
                    "Its notes or text open here.", comment: "Notes: hint under the title when no tab is open")
            ) {}
        }
    }
}

/// Grey bars where the text will be (prototype `.skel`).
struct NoteSkeletonBar: View {
    var width: CGFloat = 1
    var height: CGFloat = 1
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 6).fill(LintelBrand.fill)
                .frame(width: proxy.size.width * width)
        }
        .frame(height: 12.5 * textSize.scale * height)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }
}

struct NoteSkeletonDocument: View {
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoteSkeletonBar(width: 0.4, height: 1.8)
            NoteSkeletonBar(width: 0.3)
            NoteSkeletonBar().padding(.top, 16 * textSize.scale)
            NoteSkeletonBar()
            NoteSkeletonBar(width: 0.7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40 * textSize.scale)
        .padding(.vertical, 28 * textSize.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading notes", comment: "Accessibility label while the notes are read"))
    }
}

/// The explorer body when there is no list to show (prototype `.nr`, `.skel` rows).
struct ExplorerPlaceholder: View {
    let screen: NotesWorkspaceModel.Screen
    var collection: NoteCollection = .notes
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        switch screen {
        case .loading:
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(alignment: .top, spacing: 9 * textSize.scale) {
                        Circle().fill(LintelBrand.hairline)
                            .frame(width: 7 * textSize.scale, height: 7 * textSize.scale)
                            .padding(.top, 8 * textSize.scale)
                        VStack(alignment: .leading, spacing: 0) {
                            NoteSkeletonBar(width: 0.75)
                            NoteSkeletonBar(width: 0.45)
                        }
                    }
                    .padding(.horizontal, 16 * textSize.scale)
                    .padding(.vertical, 6 * textSize.scale)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Loading notes", comment: "Accessibility label while the notes are read"))
        case .locked:
            VStack(spacing: 6) {
                Image(systemName: "lock").accessibilityHidden(true)
                Text("Locked", comment: "Explorer: the notes are locked")
            }
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(18 * textSize.scale)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        case .empty:
            (collection == .dictations
                ? Text("No dictations yet.", comment: "Dictation history empty state")
                : Text("No notes yet.", comment: "Explorer: the library is empty"))
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                .padding(18 * textSize.scale)
                .frame(maxWidth: .infinity)
        case .noResults(let query):
            VStack(spacing: 0) {
                if collection == .dictations {
                    Text(
                        "No dictations match “\(query)”.",
                        comment: "Explorer: a search in the dictations found nothing; the query")
                } else {
                    Text("No notes match “\(query)”.", comment: "Explorer: a search found nothing; the query")
                }
                Text(
                    "Search covers titles, notes, transcripts and dictations.",
                    comment: "Explorer: what a search looks in")
            }
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.secondaryText)
            .multilineTextAlignment(.center)
            .padding(18 * textSize.scale)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        case .list:
            EmptyView()
        }
    }
}

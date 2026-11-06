import LintelKit
import LintelUI
import SwiftUI

/// The tab bar (prototype `.tbs`): one tab per open note with its icon, title, a busy mark and a close button.
/// The selected tab has the window's background and the accent line under it.
struct NoteTabBar: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs.tabs) { tab in
                        NoteTabView(model: model, tab: tab, isSelected: model.currentID == tab.id)
                    }
                    NewNoteButton(model: model, style: .tab)
                }
            }
            .frame(height: 33.75 * textSize.scale)
            .background(LintelBrand.sidebarBackground)
            LintelDivider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Open notes", comment: "Accessibility label of the tab bar"))
    }
}

struct NoteTabView: View {
    let model: NotesWorkspaceModel
    let tab: NoteTab
    let isSelected: Bool
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.select(tab.id)
            } label: {
                HStack(spacing: 7 * textSize.scale) {
                    Image(systemName: tab.kind.symbolName)
                        .accessibilityHidden(true)
                    Text(verbatim: tab.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if tab.isBusy {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(textSize.font(.caption1))
                            .foregroundStyle(LintelBrand.accentText)
                            .accessibilityHidden(true)
                    }
                }
                .font(textSize.font(.callout))
                .foregroundStyle(isSelected ? LintelBrand.ink : LintelBrand.secondaryText)
                .padding(.leading, 12 * textSize.scale)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(
                    verbatim: tab.isBusy
                        ? "\(tab.title), \(String(localized: "Working", comment: "Accessibility: a note is being worked on"))"
                        : tab.title)
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button {
                model.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(textSize.font(.caption2, weight: .semibold))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .opacity(0.8)
                    .frame(width: 24 * textSize.scale, height: 24 * textSize.scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4 * textSize.scale)
            .accessibilityLabel(Text("Close tab", comment: "Accessibility label of a tab's close button"))
        }
        .frame(minWidth: 96 * textSize.scale, maxWidth: 15 * 12.5 * textSize.scale)
        .frame(maxHeight: .infinity)
        .background(isSelected ? LintelBrand.windowBackground : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected { LintelBrand.accent.frame(height: 2) }
        }
        .overlay(alignment: .trailing) { LintelDivider(axis: .vertical) }
    }
}

/// The path bar (prototype `.crb`): where the note sits in the explorer, in the monospaced face, and the two
/// actions of a read-only note: Copy Markdown (⌘⇧C) and Save .md….
struct NotePathBar: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let path = model.pathComponents {
                    Text(verbatim: path.joined(separator: " / "))
                        .font(textSize.font(.footnote).monospaced())
                        .foregroundStyle(LintelBrand.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(Text(verbatim: path.joined(separator: ", ")))
                }
                Spacer(minLength: 0)
                if let feedback = model.feedback, !feedback.isStrip {
                    Text(verbatim: Self.text(feedback))
                        .font(textSize.font(.footnote))
                        .foregroundStyle(LintelBrand.accentText)
                        .accessibilityHidden(true)
                }
                if model.currentDocument?.markdown != nil { actions }
            }
            .padding(.leading, 16 * textSize.scale)
            .padding(.trailing, 12 * textSize.scale)
            .frame(height: 32.5 * textSize.scale)
            LintelDivider()
            ForEach(model.strips) { strip in NoteStripView(strip: strip, model: model) }
        }
        .accessibilityElement(children: .contain)
        .task(id: model.feedbackSerial) {
            guard let feedback = model.feedback else { return }
            AccessibilityNotification.Announcement(Self.text(feedback)).post()
            // The save-error strip stays until it is dismissed or the save is tried again.
            guard !feedback.isStrip else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { model.dismissFeedback() }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if let document = model.currentDocument, model.canEdit(document) || document.isEditing {
                // Prototype `.ib.on`: the pen is lit while the note is in the editor.
                iconButton(
                    "pencil",
                    label: document.isEditing
                        ? Text("Done editing", comment: "Path bar: leaves the editor")
                        : Text("Edit", comment: "Path bar: opens the note in the editor"),
                    tint: document.isEditing ? LintelBrand.accentText : LintelBrand.secondaryText
                ) {
                    model.toggleEditing()
                }
                .background(
                    document.isEditing ? LintelBrand.windowSelectionTint : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .accessibilityAddTraits(document.isEditing ? .isSelected : [])
            }
            iconButton("doc.on.doc", label: Text("Copy Markdown", comment: "Path bar: copies the note as Markdown")) {
                model.copyMarkdown()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            if !model.inspectorVisible {
                iconButton(
                    "sidebar.right", label: Text("Show the inspector", comment: "Path bar: shows the inspector")
                ) {
                    model.inspectorVisible = true
                }
            }
            iconButton(
                "square.and.arrow.down",
                label: Text("Save .md…", comment: "Path bar: saves the note as a Markdown file")
            ) {
                Task { await model.saveMarkdown() }
            }
        }
    }

    private func iconButton(
        _ symbol: String, label: Text, tint: Color = LintelBrand.secondaryText, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(textSize.font(.callout))
                .foregroundStyle(tint)
                .frame(width: 26.25 * textSize.scale, height: 26.25 * textSize.scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    static func text(_ feedback: NotesWorkspaceModel.Feedback) -> String {
        switch feedback {
        case .copied: String(localized: "Copied", comment: "Path bar: the Markdown was copied")
        case .saved: String(localized: "Saved", comment: "Path bar: the Markdown file was saved")
        case .saveFailed:
            String(
                localized: "The .md file couldn’t be saved. Check that the folder is writable.",
                comment: "Notes: saving the Markdown file failed")
        case .createFailed:
            String(localized: "The note couldn’t be created.", comment: "Notes: a new note could not be written")
        case .titleFailed:
            String(localized: "The title couldn’t be saved.", comment: "Notes: a note's title could not be written")
        case .deleted:
            String(localized: "note.deleted", defaultValue: "Deleted", comment: "Path bar: the note was deleted")
        case .deleteFailed:
            String(
                localized: "The note couldn’t be deleted. Nothing was changed.",
                comment: "Notes: deleting a note failed or was refused")
        case .copyNotRemoved:
            String(
                localized: "The note was deleted, but the copy in Notes couldn’t be removed yet.",
                comment: "Notes: the owner deleted the note but its edited copy stayed")
        case .restored:
            String(localized: "Version restored", comment: "Path bar: an earlier version became the current text")
        case .restoreChanged:
            String(
                localized: "The note changed in the meantime. Open the history again and restore from there.",
                comment: "Notes: a restore was refused because the note changed meanwhile")
        case .restoreReadOnly:
            String(
                localized: "Notes are read-only, so nothing can be restored.",
                comment: "Notes: a restore was refused because editing is off")
        case .restoreTargetInvalid:
            String(
                localized: "That is not an earlier saved version of this note. Nothing was changed.",
                comment: "Notes: a restore target was not an earlier applied version")
        case .commentFailed:
            String(
                localized: "The comment couldn’t be saved. Nothing was changed.",
                comment: "Notes: writing a comment failed")
        case .commentReadOnly:
            String(
                localized: "Notes are read-only, so nothing can be commented.",
                comment: "Notes: a comment was refused because editing is off")
        case .commentChanged:
            String(
                localized: "That text is not in the saved note. Select it again.",
                comment: "Notes: a comment was refused because the selected text is not in the saved note")
        case .commentTooLong:
            String(
                localized: "That comment is too long. Shorten it; nothing was saved.",
                comment: "Notes: a comment was refused because it is longer than the limit")
        case .commentSelectionTooLong:
            String(
                localized: "That passage is too long to comment on. Select a shorter one.",
                comment: "Notes: a comment was refused because the selected passage is too long")
        case .commentSelectionInvalid:
            String(
                localized: "Select some text in the note first, then comment.",
                comment: "Notes: a comment was refused because the selection is empty or outside the note")
        case .restoreFailed:
            String(
                localized: "That version couldn’t be restored. Nothing was changed.",
                comment: "Notes: restoring an earlier version failed")
        }
    }
}

/// The status bar (prototype `.sbar`): what is true of the whole section, in words.
struct NotesStatusBar: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            LintelDivider()
            HStack(spacing: 14) {
                if let line = model.statusLine { StatusLineView(line: line) }
                if model.showsEncryptionNote {
                    Label {
                        Text("Encrypted on this Mac", comment: "Notes status bar: where the notes are stored")
                    } icon: {
                        Image(systemName: "lock")
                    }
                }
                Spacer(minLength: 0)
                Text(verbatim: model.statusRight)
            }
            .font(textSize.font(.footnote))
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(.horizontal, 12 * textSize.scale)
            .frame(height: 26 * textSize.scale)
            .background(LintelBrand.sidebarBackground)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The dot or the spinner, the words and, while the length is known, the progress bar (prototype `.pb`).
struct StatusLineView: View {
    let line: NotesWorkspaceModel.StatusLine
    @Environment(\.lintelTextSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            switch line.kind {
            case .busy:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(LintelBrand.accentText)
                    .accessibilityHidden(true)
            default:
                Circle().fill(color).frame(width: 7 * textSize.scale, height: 7 * textSize.scale)
                    .accessibilityHidden(true)
            }
            Text(verbatim: line.text)
            if case .busy(let progress?) = line.kind {
                ZStack(alignment: .leading) {
                    Capsule().fill(LintelBrand.hairline)
                    GeometryReader { proxy in
                        Capsule().fill(LintelBrand.accent).frame(width: proxy.size.width * progress)
                    }
                }
                .frame(width: 8 * 12.5 * textSize.scale, height: 4)
                .padding(.leading, 2)
                .accessibilityHidden(true)
            }
        }
    }

    private var color: Color {
        switch line.kind {
        case .ok: LintelBrand.statusOk
        case .attention: LintelBrand.statusAttention
        case .error: LintelBrand.statusError
        default: LintelBrand.hairline
        }
    }
}

/// "New note" (⌘N): the explorer's "+" and the tab bar's plus tab (prototype `.ico` and `.tb.pl`).
struct NewNoteButton: View {
    enum Style { case explorer, tab }
    let model: NotesWorkspaceModel
    let style: Style
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Button {
            Task { await model.newNote() }
        } label: {
            Image(systemName: "plus")
                .font(textSize.font(style == .tab ? .callout : .caption1, weight: .semibold))
                .foregroundStyle(LintelBrand.secondaryText)
                .padding(.horizontal, style == .tab ? 12 : 4)
                .frame(maxHeight: style == .tab ? .infinity : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canCreateNote)
        .accessibilityLabel(Text("New note", comment: "Accessibility label of the new-note button"))
        .help(Text("New note (⌘N)", comment: "Tooltip of the new-note button"))
    }
}

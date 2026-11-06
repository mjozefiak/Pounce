import LintelKit
import LintelUI
import SwiftUI

/// Comments (prototype `commentsPane`): the Open and Resolved chips, then one card per thread with its quote, the
/// comments, and Reply, Resolve or Reopen. The footer with "Revise with N comments" is `NoteCommentsFooter`.
struct NoteCommentsPane: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                chip(
                    .open, count: document.openThreads.count,
                    title: {
                        Text("Open \($0)", comment: "Inspector, Comments: filter of the open threads and how many")
                    })
                chip(
                    .resolved, count: document.resolvedThreads.count,
                    title: {
                        Text(
                            "Resolved \($0)",
                            comment: "Inspector, Comments: filter of the resolved threads and how many")
                    })
            }
            .padding(.bottom, 8)
            switch document.comments {
            case .idle, .loading:
                note(Text("Loading comments…", comment: "Inspector, Comments: while the comments are read"))
            case .failed:
                note(
                    Text(
                        "Comments can’t be read right now. Nothing was changed.",
                        comment: "Inspector, Comments: notes.sqlite could not be read"))
            case .none:
                note(emptyHint)
            case .loaded:
                if document.shownThreads.isEmpty {
                    note(
                        document.commentFilter == .open
                            ? Text("No open comments.", comment: "Inspector, Comments: nothing is open")
                            : Text("No resolved comments.", comment: "Inspector, Comments: nothing is resolved"))
                }
                ForEach(document.shownThreads) { thread in
                    NoteThreadCard(model: model, document: document, thread: thread)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Comments", comment: "Accessibility label of the comment list"))
    }

    private var emptyHint: Text {
        document.commentFilter == .open
            ? Text(
                "No comments yet. Select text in the editor and choose Comment.",
                comment: "Inspector, Comments: how to start a comment")
            : Text("No resolved comments.", comment: "Inspector, Comments: nothing is resolved")
    }

    private func note(_ text: Text) -> some View {
        text
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Prototype `.chip3`: a hairline pill, on = tinted with the accent text.
    private func chip(_ filter: CommentFilter, count: Int, title: (Int) -> Text) -> some View {
        let isOn = document.commentFilter == filter
        return Button {
            document.commentFilter = filter
        } label: {
            title(count)
                .font(textSize.font(.footnote))
                .foregroundStyle(isOn ? LintelBrand.accentText : LintelBrand.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .background(isOn ? LintelBrand.windowSelectionTint : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(isOn ? Color.clear : LintelBrand.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One thread (prototype `.th`): the quote with the accent rule, who and when, the text, then the actions.
struct NoteThreadCard: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    let thread: CommentThread
    @State private var isReplying = false
    @State private var replyText = ""
    @Environment(\.lintelTextSize) private var textSize

    private var canWrite: Bool { model.canWriteComments(document) }
    private var textChanged: Bool { thread.isOpen && document.isTextChanged(thread) }
    private var isSelected: Bool { document.selectedThreadID == thread.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "“\(thread.displayQuote)”")
                .font(textSize.font(.footnote))
                .foregroundStyle(LintelBrand.secondaryText)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(LintelBrand.accent).frame(width: 2) }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
            if textChanged {
                Text("Text changed", comment: "Inspector, Comments: the commented text is no longer in the note")
                    .font(textSize.font(.caption1, weight: .semibold))
                    .foregroundStyle(LintelBrand.statusAttention)
            }
            ForEach(thread.comments) { comment in
                commentRow(comment)
            }
            actions
            if isReplying { replyField }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LintelBrand.windowBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? LintelBrand.accent : LintelBrand.hairline))
        .opacity(thread.isOpen ? 1 : 0.6)
        .padding(.bottom, 8)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { select() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: thread.spokenTitle(textChanged: textChanged)))
    }

    private func select() {
        document.selectedThreadID = thread.id
    }

    private func commentRow(_ comment: CommentRecord) -> some View {
        let when = model.presentation.historyTime(comment.createdAt, now: model.environment.now())
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text(verbatim: CommentThread.authorName(comment.author))
                    .font(textSize.font(.footnote, weight: .semibold))
                    .foregroundStyle(LintelBrand.ink)
                Text(verbatim: " · \(when)")
                    .font(textSize.font(.footnote))
                    .foregroundStyle(LintelBrand.secondaryText)
            }
            .accessibilityHidden(true)
            Text(verbatim: comment.body)
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(verbatim: CommentThread.spokenMeta(author: comment.author, when: when) + ". " + comment.body))
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if canWrite && thread.isOpen {
                link(Text("Reply", comment: "Inspector, Comments: answers a thread")) { isReplying.toggle() }
            }
            if canWrite {
                if thread.isOpen {
                    link(Text("Resolve", comment: "Inspector, Comments: closes a thread")) {
                        Task { await model.setStatus(.resolved, of: thread) }
                    }
                } else {
                    link(Text("Reopen", comment: "Inspector, Comments: opens a resolved thread again")) {
                        Task { await model.setStatus(.open, of: thread) }
                    }
                }
            }
            if canWrite && textChanged && document.isEditing {
                link(
                    Text(
                        "Use selection",
                        comment: "Inspector, Comments: points a thread whose text changed at the selected text")
                ) { Task { await model.reanchor(thread) } }
            }
        }
    }

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                text: $replyText, axis: .vertical,
                label: { Text("Reply", comment: "Accessibility label of the reply field") }
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .font(textSize.font(.callout))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(LintelBrand.accent))
            HStack(spacing: 12) {
                link(Text("Cancel", comment: "Comment popover: closes without writing")) {
                    isReplying = false
                    replyText = ""
                }
                link(Text("Send", comment: "Inspector, Comments: sends a reply")) {
                    Task {
                        if await model.reply(to: thread, body: replyText) {
                            replyText = ""
                            isReplying = false
                        }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
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

/// The footer under the threads (prototype `.ipb`): the primary button with the number of open threads, and what
/// it does. The agent comes in step 6.2: until then the button is off, but its count and label are real.
struct NoteCommentsFooter: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 6) {
            Button {
                Task { await model.revise() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                    Text(NoteCommentsFooter.reviseTitle(model.reviseCount))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LintelPrimaryButtonStyle())
            .disabled(!model.canRevise)
            Text(
                "The agent rewrites only commented blocks. Your edits stay.",
                comment: "Inspector, Comments: what Revise does"
            )
            .font(textSize.font(.footnote))
            .foregroundStyle(LintelBrand.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { LintelDivider() }
    }

    /// "Revise with 2 comments": the count is a plural variable (Polish has one, few, many and other).
    static func reviseTitle(_ count: Int) -> LocalizedStringKey {
        "Revise with \(count) comments"
    }
}

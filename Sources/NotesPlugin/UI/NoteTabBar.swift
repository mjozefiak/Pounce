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
                if let feedback = model.feedback, feedback != .saveFailed {
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
            guard feedback != .saveFailed else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { model.dismissFeedback() }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            iconButton("doc.on.doc", label: Text("Copy Markdown", comment: "Path bar: copies the note as Markdown")) {
                model.copyMarkdown()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            iconButton(
                "square.and.arrow.down",
                label: Text("Save .md…", comment: "Path bar: saves the note as a Markdown file")
            ) {
                Task { await model.saveMarkdown() }
            }
        }
    }

    private func iconButton(_ symbol: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
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

import SwiftUI

/// The meeting window: banners, the speakers, then the transcript in a lazy list (a 3 hour meeting has
/// thousands of segments). Semantic colours and text styles only; the text size comes from the environment.
struct MeetingWindowView: View {
    @Bindable var model: MeetingWindowModel
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .loading:
                ProgressView {
                    Text("Loading…", comment: "Meeting window while the meeting loads")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                MessageView(
                    symbol: "questionmark.folder",
                    text: Text("This meeting no longer exists.", comment: "Meeting window: meeting not found"))
            case .failed:
                MessageView(
                    symbol: "exclamationmark.triangle",
                    text: Text("The meeting could not be opened.", comment: "Meeting window: read error"))
            case .loaded:
                loaded
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task {
            await model.load()
            model.follow()
        }
        .onDisappear { model.stopFollowing() }
        .confirmationDialog(
            Text("Delete this meeting?", comment: "Meeting window: delete confirmation title"),
            isPresented: $model.isConfirmingDelete
        ) {
            Button(role: .destructive) {
                Task { await model.confirmDelete() }
            } label: {
                Text("Delete Meeting", comment: "Meeting window: confirm deleting")
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", comment: "Meeting window: cancel deleting")
            }
        } message: {
            Text(
                "The transcript, notes and any saved audio are removed from this Mac. This cannot be undone.",
                comment: "Meeting window: delete confirmation message")
        }
    }

    private var loaded: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ForEach(Array(model.banners.enumerated()), id: \.offset) { _, banner in
                BannerView(banner: banner, model: model)
            }
            if let offer = model.gapOffer, !model.isFinishing {
                GapOfferView(offer: offer, model: model)
            }
            if model.isEmpty {
                MessageView(
                    symbol: "text.bubble",
                    text: Text("There is no transcript for this meeting.", comment: "Meeting window: no segments"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        speakersSection
                        ForEach(model.document?.segments ?? []) { segment in
                            SegmentRow(segment: segment, model: model, contrast: contrast)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityLabel(Text("Transcript", comment: "Accessibility label of the transcript list"))
            }
            Divider()
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(
                    text: $titleDraft,
                    prompt: Text(verbatim: model.title)
                ) {
                    Text("Title", comment: "Meeting window: label of the title field")
                }
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                .onChange(of: titleDraft) { _, draft in model.pendingTitle = draft }
                .accessibilityLabel(Text("Title", comment: "Meeting window: label of the title field"))
                .accessibilityHint(
                    Text("Edit the meeting title, then press Return", comment: "Hint of the title field"))
                Spacer(minLength: 0)
            }
            if let document = model.document {
                Text(Self.metadata(document))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .onAppear { titleDraft = model.document?.title ?? "" }
        .onChange(of: model.document?.title) { _, title in
            if !titleFocused {
                titleDraft = title ?? ""
                model.pendingTitle = nil
            }
        }
    }

    private func commitTitle() {
        let draft = titleDraft
        Task { await model.renameTitle(draft) }
    }

    static func metadata(_ document: MeetingDocument) -> String {
        var parts = [document.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if document.durationMs > 0 {
            parts.append(MarkdownExporter.clock(milliseconds: document.durationMs))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Speakers

    @ViewBuilder
    private var speakersSection: some View {
        if !model.speakers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers", comment: "Meeting window: heading of the speaker list")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(model.speakers.enumerated()), id: \.element.id) { index, speaker in
                    SpeakerRow(speaker: speaker, index: index, model: model)
                }
                Text(
                    "Renaming a speaker changes the name in the transcript at once. Notes already written change after you regenerate them.",
                    comment: "Meeting window: hint under the speaker list"
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let feedback = model.feedback { FeedbackLine(feedback: feedback) }
            if let why = model.regenerateExplanation {
                Text(why).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            model.copyMarkdown()
        } label: {
            Label {
                Text("Copy Markdown", comment: "Meeting window button")
            } icon: {
                Image(systemName: "doc.on.doc")
            }
        }
        .disabled(!model.canCopy)
        .accessibilityHint(
            Text(
                "Copies the meeting as Markdown. Lintel's clipboard history does not keep it.",
                comment: "Hint of Copy Markdown"))
        Button {
            Task { await model.saveMarkdown() }
        } label: {
            Label {
                Text("Save .md…", comment: "Meeting window button")
            } icon: {
                Image(systemName: "square.and.arrow.down")
            }
        }
        .disabled(!model.canSave)
        .accessibilityHint(Text("Saves the meeting as a Markdown file", comment: "Hint of Save .md"))
        Button {
            model.regenerateNotes()
        } label: {
            Label {
                Text("Regenerate Notes", comment: "Meeting window button")
            } icon: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(!model.canRegenerate)
        .accessibilityHint(
            Text(
                model.regenerateExplanation
                    ?? String(
                        localized: "Writes the notes again from the transcript", comment: "Hint of Regenerate Notes"))
        )
        Spacer(minLength: 0)
        Button(role: .destructive) {
            model.requestDelete()
        } label: {
            Label {
                Text("Delete…", comment: "Meeting window button")
            } icon: {
                Image(systemName: "trash")
            }
        }
        .disabled(!model.canDelete)
        .accessibilityHint(Text("Asks before deleting this meeting", comment: "Hint of Delete"))
    }
}

// MARK: - Pieces

/// Colours of the speaker bands, by position in the speaker list. Names are always shown too, so colour is
/// never the only cue.
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .mint, .brown, .cyan]

    static func color(_ index: Int?) -> Color {
        guard let index else { return .secondary }
        return colors[index % colors.count]
    }
}

private struct SpeakerRow: View {
    let speaker: MeetingDocument.Speaker
    let index: Int
    @Bindable var model: MeetingWindowModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(SpeakerPalette.color(index)).frame(width: 4, height: 20)
                .accessibilityHidden(true)
            TextField(text: $draft) {
                Text("Speaker name", comment: "Meeting window: label of a speaker name field")
            }
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .accessibilityLabel(Text("Speaker name", comment: "Meeting window: label of a speaker name field"))
            .accessibilityValue(Text(speaker.label))
            .accessibilityHint(Text("Rename this speaker, then press Return", comment: "Hint of a speaker name field"))
            if speaker.isSelf {
                Label {
                    Text("You", comment: "Meeting window: marks the speaker who is the user")
                } icon: {
                    Image(systemName: "person.crop.circle.fill")
                }
                .font(.callout).foregroundStyle(.secondary)
            } else if model.canMarkSelf(speaker) {
                Button {
                    Task { await model.markSelf(speaker.id) }
                } label: {
                    Text("This is me", comment: "Meeting window button: mark this speaker as the user")
                }
                .accessibilityLabel(
                    Text("This is me, \(speaker.label)", comment: "Accessibility label of This is me; the speaker"))
            }
        }
        .onAppear { draft = speaker.label }
        // The row is lazy and can scroll away with a half-typed name: save it then.
        .onDisappear { commit() }
        .onChange(of: speaker.label) { _, label in if !focused { draft = label } }
    }

    private func commit() {
        let value = draft
        if MeetingWindowModel.visible(value).isEmpty {
            draft = speaker.label
            return
        }
        if value == speaker.label { return }
        Task { await model.renameSpeaker(speaker.id, to: value) }
    }
}

private struct SegmentRow: View {
    let segment: MeetingDocument.Segment
    let model: MeetingWindowModel
    let contrast: ColorSchemeContrast

    var body: some View {
        let name = model.speakerName(for: segment)
        let time = MarkdownExporter.clock(milliseconds: segment.startMs)
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(SpeakerPalette.color(model.colorIndex(of: segment.speakerID)))
                .frame(width: contrast == .increased ? 6 : 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name).font(.subheadline.weight(.semibold))
                    Text(verbatim: time).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(verbatim: segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(name), \(time)", comment: "Accessibility label of a transcript row; speaker, time"))
        .accessibilityValue(Text(verbatim: segment.text))
    }
}

private struct BannerView: View {
    let banner: MeetingWindowModel.Banner
    let model: MeetingWindowModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            message.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if case .incomplete(let canFinish) = banner, canFinish {
                Button {
                    Task { await model.finish() }
                } label: {
                    Text("Finish", comment: "Meeting window button that finishes an interrupted meeting")
                }
                .accessibilityHint(
                    Text("Transcribes the rest of the recording", comment: "Hint of the Finish button"))
            }
            if banner == .finishing { ProgressView().controlSize(.small) }
            if case .notesWriting = banner { ProgressView().controlSize(.small) }
            if banner == .notesNeedsModel {
                Button {
                    model.downloadNotesModel()
                } label: {
                    Text("Download Notes Model", comment: "Meeting window button that opens the notes model settings")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.quaternary)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch banner {
        case .speakersUnavailable: "person.2.slash"
        case .incomplete, .finishing: "exclamationmark.circle"
        case .failed: "xmark.octagon"
        case .processing: "hourglass"
        case .notesStale: "clock.arrow.circlepath"
        case .notesWriting: "text.badge.checkmark"
        case .notesFailed: "exclamationmark.triangle"
        case .notesPartial: "exclamationmark.circle"
        case .notesDropped: "checkmark.shield"
        case .notesNeedsModel: "arrow.down.circle"
        }
    }

    @ViewBuilder
    private var message: some View {
        switch banner {
        case .speakersUnavailable:
            Text(
                "Speaker recognition is unavailable – speakers are split into you and others",
                comment: "Meeting window banner when speakers are the two audio tracks")
        case .incomplete(let canFinish):
            if canFinish {
                Text(
                    "Recording was interrupted. The transcript may be missing its end.",
                    comment: "Meeting window banner for an interrupted meeting that can be finished")
            } else {
                Text(
                    "Recording was interrupted and the audio is gone, so this transcript is all there is.",
                    comment: "Meeting window banner for an interrupted meeting that cannot be finished")
            }
        case .finishing:
            Text("Finishing the transcript…", comment: "Meeting window banner while Finish runs")
        case .failed:
            Text(
                "This meeting could not be processed. What was saved is shown below.",
                comment: "Meeting window banner for a failed meeting")
        case .processing:
            Text("The transcript is still being prepared.", comment: "Meeting window banner while processing")
        case .notesStale:
            Text(
                "A speaker was renamed, so the notes may be out of date.",
                comment: "Meeting window banner when notes are stale")
        case .notesWriting(let phase):
            Text(verbatim: phase.map(MeetingLibraryPresentation.notesBadge(for:)) ?? NotesMessages.writing)
        case .notesFailed:
            Text(
                "The notes could not be written. The transcript is unchanged; try Regenerate Notes.",
                comment: "Meeting window banner when the notes failed")
        case .notesPartial:
            Text(
                "The notes miss some parts of the recording that could not be read. Regenerate Notes to try again.",
                comment: "Meeting window banner for partial notes")
        case .notesDropped(let count):
            Text(verbatim: NotesMessages.dropped(count))
        case .notesNeedsModel:
            Text(
                "Notes are on, but their model is not downloaded.",
                comment: "Meeting window banner when the notes model is missing")
        }
    }
}

/// "Dokończ" could not read some audio: the user decides whether to close the meeting with a gap.
private struct GapOfferView: View {
    let offer: MeetingWindowModel.GapOffer
    let model: MeetingWindowModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary).accessibilityHidden(true)
            message.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                Task { await model.finish(acceptGap: true) }
            } label: {
                Text("Finish with a Gap", comment: "Meeting window button: close the meeting although audio is missing")
            }
            .accessibilityHint(
                Text(
                    "Closes the meeting from the transcript that exists, without the unreadable audio",
                    comment: "Hint of Finish with a Gap"))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.quaternary)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var message: some View {
        switch offer {
        case .audioUnreadable:
            Text(
                "The recording cannot be read, so the rest of it cannot be transcribed.",
                comment: "Meeting window: the saved audio of an interrupted meeting is unreadable")
        case .unfinished:
            Text(
                "Some of the recording could not be transcribed.",
                comment: "Meeting window: part of the audio of an interrupted meeting failed")
        }
    }
}

private struct FeedbackLine: View {
    let feedback: MeetingWindowModel.Feedback

    var body: some View {
        text.font(.callout).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }

    private var text: Text {
        switch feedback {
        case .copied: Text("Markdown copied", comment: "Meeting window feedback after Copy Markdown")
        case .saved: Text("Markdown saved", comment: "Meeting window feedback after Save")
        case .saveFailed: Text("The file could not be saved.", comment: "Meeting window feedback")
        case .finishUnavailable:
            Text("This meeting cannot be finished now.", comment: "Meeting window feedback when Finish is refused")
        case .actionFailed: Text("The change could not be saved.", comment: "Meeting window feedback")
        case .deleteFailed:
            Text(
                "The meeting was not deleted: its audio could not be removed. Try again.",
                comment: "Meeting window feedback when deleting failed")
        }
    }
}

private struct MessageView: View {
    let symbol: String
    let text: Text

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            text.foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

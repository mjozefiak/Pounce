import LintelProviders
import LintelSpeech
import LintelUI
import SwiftUI

/// One row of a popover menu (mockup v2: a symbol, a title, a grey line under it, a check on the chosen one).
struct ChoiceMenuItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var symbol: String
    var enabled = true
}

struct ChoiceMenuGroup: Identifiable {
    var id: String
    /// The small capital heading ("On this Mac"); `nil` for none.
    var header: String?
    var items: [ChoiceMenuItem]
}

/// The value button of a settings row that opens a grouped menu in a popover: native menus cannot show a grey
/// line under a title or group headings, and the provider list has both. Keyboard: the button and every row are
/// focusable and Return/Space chooses; Escape closes.
struct ChoiceMenuButton: View {
    let title: String
    let symbol: String
    let groups: [ChoiceMenuGroup]
    let selection: String
    /// "Add provider…" style row under the groups; `nil` for none.
    var footer: ChoiceMenuItem?
    @Binding var isOpen: Bool
    var accessibilityLabel: Text
    let onSelect: (String) -> Void

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(verbatim: title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(textSize.font(.caption1)).accessibilityHidden(true)
            }
            .font(textSize.font(.body))
            .foregroundStyle(LintelBrand.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text(verbatim: title))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { menu }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups) { group in
                if let header = group.header {
                    Text(verbatim: header.uppercased())
                        .font(textSize.font(.caption1, weight: .semibold))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .padding(.horizontal, 10).padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.items) { item in row(item) }
            }
            if let footer {
                LintelDivider().padding(.vertical, 4)
                row(footer, plain: true)
            }
        }
        .padding(8)
        .frame(width: 270 * textSize.scale)
    }

    private func row(_ item: ChoiceMenuItem, plain: Bool = false) -> some View {
        let chosen = item.id == selection && !plain
        return Button {
            isOpen = false
            onSelect(item.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(textSize.font(.caption1, weight: .semibold))
                    .frame(width: 12)
                    .opacity(chosen ? 1 : 0)
                    .accessibilityHidden(true)
                Image(systemName: item.symbol).frame(width: 16).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.title).font(textSize.font(.body))
                    if let subtitle = item.subtitle {
                        Text(verbatim: subtitle)
                            .font(textSize.font(.caption1))
                            .foregroundStyle(LintelBrand.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(chosen ? LintelBrand.windowSelectionTint : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.5)
        .accessibilityLabel(Text(verbatim: [item.title, item.subtitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// "Notes are written by": the provider menu, the model menu, status and test, the notice. Mockup v2 screens
/// A-local, A2, B, and the status rows of C. The banner (the host's) carries the state; the rows repeat the facts.
struct NotesWrittenByRows: View {
    @Bindable var provider: ProviderChoiceModel
    let notes: NotesSettingsModel

    @Environment(\.lintelTextSize) private var textSize
    @State private var providerMenuOpen = false
    @State private var modelMenuOpen = false

    var body: some View {
        providerRow
        modelRow
        if provider.showsHeavierNote { heavierNote }
        if provider.chosen != nil {
            statusRow
            tryRow
        }
    }

    // MARK: Rows

    private var providerRow: some View {
        LabeledContent {
            ChoiceMenuButton(
                title: provider.chosen?.displayName ?? Self.localName,
                symbol: provider.chosen == nil ? "desktopcomputer" : "terminal",
                groups: providerGroups,
                selection: provider.chosen == nil ? "local" : provider.selection?.provider.rawValue ?? "local",
                footer: ChoiceMenuItem(
                    id: "add",
                    title: String(localized: "Add provider…", comment: "Provider menu: row that adds a provider"),
                    subtitle: nil, symbol: "plus", enabled: false),
                isOpen: $providerMenuOpen,
                accessibilityLabel: Text("Notes are written by", comment: "Settings → Meetings: provider menu label")
            ) { id in
                if id == "local" {
                    provider.useLocal()
                } else if let entry = provider.descriptors.first(where: { $0.id.rawValue == id }) {
                    provider.choose(entry.id)
                }
            }
        } label: {
            Text("Notes are written by", comment: "Settings → Meetings: provider menu label").font(textSize.font(.body))
        }
    }

    static var localName: String {
        String(localized: "Local", comment: "Provider menu: the built-in models on this Mac")
    }

    private var providerGroups: [ChoiceMenuGroup] {
        [
            ChoiceMenuGroup(
                id: "mac",
                header: String(localized: "On this Mac", comment: "Provider menu group: nothing leaves the Mac"),
                items: [
                    ChoiceMenuItem(
                        id: "local", title: Self.localName,
                        subtitle: String(
                            localized: "Built-in models. Nothing leaves this Mac.", comment: "Provider menu: Local"),
                        symbol: "desktopcomputer")
                ]),
            ChoiceMenuGroup(
                id: "tools",
                header: String(
                    localized: "Tools on your subscription", comment: "Provider menu group: CLIs on the user's plan"),
                items: provider.descriptors.map { descriptor in
                    ChoiceMenuItem(
                        id: descriptor.id.rawValue, title: descriptor.displayName,
                        subtitle: String(
                            localized: "\(descriptor.recipient) · through the \(descriptor.displayName) on this Mac",
                            comment: "Provider menu: the company and how the text gets there"),
                        symbol: "terminal")
                }),
        ]
    }

    private var modelRow: some View {
        LabeledContent {
            if let chosen = provider.chosen {
                ChoiceMenuButton(
                    title: provider.model?.displayName ?? "", symbol: "shippingbox",
                    groups: [
                        ChoiceMenuGroup(
                            id: "models",
                            header: String(
                                localized: "Models offered by \(chosen.displayName)",
                                comment: "Model menu heading of an external provider"),
                            items: provider.models.map { entry in
                                ChoiceMenuItem(
                                    id: entry.id, title: entry.displayName,
                                    subtitle: String(
                                        localized: "Newest \(entry.displayName) your \(chosen.displayName) knows",
                                        comment: "Model menu: an alias means the newest model of that family"),
                                    symbol: "shippingbox")
                            })
                    ],
                    selection: provider.selection?.model ?? "", isOpen: $modelMenuOpen,
                    accessibilityLabel: Text("Model", comment: "Settings → Meetings: model menu label")
                ) { provider.chooseModel($0) }
                .onChange(of: provider.modelMenuRequested) { _, requested in
                    if requested {
                        modelMenuOpen = true
                        provider.modelMenuRequested = false
                    }
                }
            } else {
                ChoiceMenuButton(
                    title: notes.model.package.title, symbol: "shippingbox",
                    groups: [
                        ChoiceMenuGroup(
                            id: "builtin",
                            header: String(
                                localized: "Built-in models", comment: "Model menu heading of the local models"),
                            items: notes.models.map { entry in
                                ChoiceMenuItem(
                                    id: entry.id, title: entry.package.title, subtitle: localSubtitle(entry),
                                    symbol: "shippingbox")
                            })
                    ],
                    selection: notes.model.id, isOpen: $modelMenuOpen,
                    accessibilityLabel: Text("Model", comment: "Settings → Meetings: model menu label")
                ) { id in Task { await notes.choose(id) } }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model", comment: "Settings → Meetings: model menu label").font(textSize.font(.body))
                if provider.isLocal {
                    Text("Used for every meeting.", comment: "Settings → Meetings: help under the local model")
                        .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
                }
            }
        }
    }

    private func localSubtitle(_ entry: LLMModel) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(entry.package.totalBytes), countStyle: .file)
        let memory = ByteCountFormatter.string(fromByteCount: Int64(entry.minimumMemoryBytes), countStyle: .memory)
        let state =
            entry.id == notes.model.id
            ? (notes.isInstalled
                ? String(localized: "installed", comment: "Local model state")
                : String(localized: "not installed", comment: "Local model state")) : nil
        let fit = String(localized: "for \(memory) Macs and up", comment: "Local model: the least memory")
        return [size, state, fit].compactMap { $0 }.joined(separator: " · ")
    }

    private var heavierNote: some View {
        Text(
            "This model uses more of your subscription’s limit and takes longer than Sonnet.",
            comment: "Settings → Meetings: note under the model menu for Opus and Fable"
        )
        .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusRow: some View {
        LabeledContent {
            statusText
        } label: {
            Text("Status", comment: "Settings → Meetings: provider status row").font(textSize.font(.body))
        }
    }

    @ViewBuilder private var statusText: some View {
        let name = provider.chosen?.displayName ?? ""
        switch provider.check {
        case .unknown, .checking:
            Text("Checking…", comment: "Settings → Meetings: the provider is being looked at")
                .font(textSize.font(.body)).foregroundStyle(LintelBrand.secondaryText)
        case .known(let status):
            switch status {
            case .ready:
                Text(
                    provider.version.map {
                        String(
                            localized: "✓ \(name) \($0), signed in",
                            comment: "Settings → Meetings status: the provider's CLI works; name, version")
                    }
                        ?? String(
                            localized: "✓ \(name), signed in", comment: "Settings → Meetings status: the CLI works")
                )
                .font(textSize.font(.body)).foregroundStyle(LintelBrand.statusOk)
            case .notInstalled:
                Text("Not installed", comment: "Settings → Meetings status: no CLI")
                    .font(textSize.font(.body)).foregroundStyle(LintelBrand.statusAttention)
            case .notSignedIn:
                Text("Not signed in", comment: "Settings → Meetings status: CLI without login")
                    .font(textSize.font(.body)).foregroundStyle(LintelBrand.statusAttention)
            case .incompatibleVersion, .newerVersion:
                Text("Incompatible version", comment: "Settings → Meetings status: CLI version not supported")
                    .font(textSize.font(.body)).foregroundStyle(LintelBrand.statusAttention)
            }
        }
    }

    private var tryRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                switch provider.testState {
                case .idle, .running: EmptyView()
                case .worked:
                    Text("It worked.", comment: "Settings → Meetings: the test text went through")
                        .foregroundStyle(LintelBrand.statusOk)
                case .failed, .unavailable:
                    Text("It didn’t work.", comment: "Settings → Meetings: the test failed")
                        .foregroundStyle(LintelBrand.statusError)
                }
                Button {
                    provider.testProvider()
                } label: {
                    Text("Test", comment: "Settings → Meetings: button that tries the provider")
                }
                .disabled(provider.testState == .running || provider.status != .ready)
            }
            .font(textSize.font(.callout))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Try it", comment: "Settings → Meetings: try the provider").font(textSize.font(.body))
                Text(
                    "Sends a short fixed example, not a meeting.",
                    comment: "Settings → Meetings: what the test sends"
                )
                .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
            }
        }
    }
}

/// The cards under the rows: the sign-in command, the D12 confirmation, the notice and its Details, the caption.
struct NotesWrittenByNotices: View {
    @Bindable var provider: ProviderChoiceModel

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        if provider.chosen != nil {
            if provider.status == .notSignedIn || provider.failure?.reason == .notSignedIn { signInCard }
            if provider.confirmingUseLocal { confirmCard }
            if let failure = provider.failure { lastMeetingRow(failure) }
            noticeCard
            SettingsFooter(
                LocalizedStringResource(
                    "Switch back to Local here at any time: no question asked. It stops further sending; it can’t recall what was sent.",
                    comment: "Settings → Meetings: caption under the notice about an external provider"))
        } else {
            SettingsFooter(
                LocalizedStringResource(
                    "Nothing leaves this Mac.", comment: "Settings → Meetings: caption under the local choice"))
        }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: ProviderChoiceModel.loginCommand).font(textSize.font(.body).monospaced())
                Spacer()
                Button {
                    provider.copyLoginCommand()
                } label: {
                    Label {
                        Text("Copy Command", comment: "Settings → Meetings: copies the sign-in command")
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
            Text("Lintel never sees your login.", comment: "Settings → Meetings: the sign-in stays in the CLI")
                .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
        }
    }

    private var confirmCard: some View {
        HStack {
            Text(
                "A job is running. What was already sent stays with the provider.",
                comment: "Settings → Meetings: asked once when Use Local is pressed during a job"
            )
            .font(textSize.font(.body)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                provider.cancelUseLocal()
            } label: {
                Text("Cancel", comment: "Button that cancels")
            }
            Button {
                provider.confirmUseLocal()
            } label: {
                Text("Use Local", comment: "Settings → Meetings banner button: back to the built-in model")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func lastMeetingRow(_ failure: ProviderJobFailure) -> some View {
        LabeledContent {
            Text("Failed", comment: "Settings → Meetings: the last meeting's notes failed")
                .foregroundStyle(LintelBrand.statusError).font(textSize.font(.body))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last meeting", comment: "Settings → Meetings: row naming the meeting that failed")
                    .font(textSize.font(.body))
                Text(verbatim: Self.lastMeetingLine(failure))
                    .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
            }
        }
    }

    static func lastMeetingLine(_ failure: ProviderJobFailure) -> String {
        let date = failure.startedAt.formatted(.dateTime.day().month(.abbreviated))
        let title = failure.title.flatMap { $0.isEmpty ? nil : $0 }
        return title.map { "\($0) · \(date)" } ?? date
    }

    private var noticeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cloud").foregroundStyle(LintelBrand.accentText).accessibilityHidden(true)
                Text(noticeText).font(textSize.font(.body)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    provider.detailsExpanded.toggle()
                } label: {
                    Text("Details", comment: "Settings → Meetings: expands the notice in place")
                        .font(textSize.font(.body, weight: .semibold)).foregroundStyle(LintelBrand.accentText)
                }
                .buttonStyle(.plain)
                .accessibilityValue(
                    provider.detailsExpanded
                        ? Text("Expanded", comment: "Disclosure state, spoken")
                        : Text("Collapsed", comment: "Disclosure state, spoken"))
            }
            if provider.detailsExpanded { ProviderDetailsList() }
        }
    }

    private var noticeText: LocalizedStringKey {
        // The company is named in bold; the sentence about the consent stays (owner decision D13).
        let recipient = provider.chosen?.recipient ?? ""
        return LocalizedStringKey(
            String(
                localized:
                    "Meeting transcripts, speaker names and your approved dictionary terms leave this Mac and go to **\(recipient)**. Choosing this provider is your consent.",
                comment: "Settings → Meetings: the short notice next to an external provider"))
    }
}

/// "Details", expanded in place (screen B): what leaves, what does not, when, and what to know.
struct ProviderDetailsList: View {
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LintelDivider()
            heading("What leaves this Mac, for every meeting")
            bullet(
                "The **whole transcript**, in one go (a very long meeting in several large parts).")
            bullet("**Speaker names**, including names you gave and your own.")
            bullet("**Timestamps** of each segment ([mm:ss]).")
            bullet(
                "Your **whole dictation vocabulary** of approved terms: correct spelling only, not the forms as heard, not unapproved suggestions. Only while Dictation is on."
            )
            heading("Not sent")
            plain(
                "Audio, meeting titles, the app a meeting came from, your own notes, the meetings vocabulary, dictated text."
            )
            heading("When it happens")
            bullet(
                "**With every meeting and with no question asked**: after each recording, when an interrupted meeting is finished (also in the background after a restart), after a speaker name changes, and on automatic retries after an error or timeout (a retry sends the transcript again)."
            )
            bullet(
                "“Regenerate notes” sends the transcript **again**, also for meetings recorded before you chose this provider."
            )
            bullet("Changing the model of the same provider asks nothing and changes nothing about what is sent.")
            heading("What you should know")
            bullet(
                "It goes through **your Claude account**, under the provider’s terms and your plan; Anthropic may keep the text."
            )
            bullet("It uses your subscription’s limit.")
            bullet("**What was sent can’t be taken back.** Switching back to Local stops further sending only.")
            bullet("No marker does not mean nothing was sent (a failed run may have sent the transcript).")
            bullet("**Lintel doesn’t tell meeting participants.** Informing them is up to you.")
        }
    }

    private func heading(_ key: LocalizedStringKey) -> some View {
        Text(key, comment: "Settings → Meetings, Details of the provider notice: section heading")
            .font(textSize.font(.caption1, weight: .semibold)).foregroundStyle(LintelBrand.secondaryText)
            .textCase(.uppercase).padding(.top, 4).accessibilityAddTraits(.isHeader)
    }

    private func bullet(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•").accessibilityHidden(true)
            Text(key, comment: "Settings → Meetings, Details of the provider notice: one point")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(textSize.font(.callout))
    }

    private func plain(_ key: LocalizedStringKey) -> some View {
        Text(key, comment: "Settings → Meetings, Details of the provider notice: what is not sent")
            .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

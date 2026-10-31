import AppKit
import PounceKit
import SwiftUI

/// What the plugin's views can ask the plugin to do.
struct ClipboardActions: Sendable {
    static let accessibilitySettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    /// Privacy & Security itself: the pasteboard setting has no documented anchor (manual QA item).
    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security")

    var resume: @MainActor @Sendable () -> Void = {}
    var retry: @MainActor @Sendable () -> Void = {}
    var dismissReset: @MainActor @Sendable () -> Void = {}
    var openAccessibilitySettings: @MainActor @Sendable () -> Void = {}
    var openPasteboardSettings: @MainActor @Sendable () -> Void = {}
}

/// The banners above the history list, most important first: the Keychain, pasteboard access, pause,
/// the reset notice and the missing Accessibility permission.
struct ClipboardStatusView: View {
    let state: ClipboardState
    let actions: ClipboardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ClipboardBanner.banners(for: state), id: \.self) { banner in
                ClipboardBannerRow(banner: banner, actions: actions)
            }
        }
    }
}

/// One status message. Order in `banners(for:)` is the display order.
enum ClipboardBanner: Hashable {
    case keychainLocked
    case keychainUnavailable
    case accessDenied
    case accessAsks
    case paused
    case historyReset
    case pasteDisabled

    @MainActor
    static func banners(for state: ClipboardState) -> [ClipboardBanner] {
        var banners: [ClipboardBanner] = []
        switch state.availability {
        case .keychainLocked: banners.append(.keychainLocked)
        case .keychainUnavailable: banners.append(.keychainUnavailable)
        case .ready, .inactive: break
        }
        switch state.access {
        case .alwaysDeny: banners.append(.accessDenied)
        case .ask: banners.append(.accessAsks)
        case .alwaysAllow, .systemDefault: break
        }
        if state.isPaused {
            banners.append(.paused)
        }
        if state.historyWasReset {
            banners.append(.historyReset)
        }
        if !state.pasteAllowed {
            banners.append(.pasteDisabled)
        }
        return banners
    }

    var symbolName: String {
        switch self {
        case .keychainLocked: "lock"
        case .keychainUnavailable: "exclamationmark.lock"
        case .accessDenied, .accessAsks: "hand.raised"
        case .paused: "pause.circle"
        case .historyReset: "arrow.counterclockwise"
        case .pasteDisabled: "keyboard"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .keychainLocked:
            LocalizedStringResource(
                "Clipboard history is unavailable while the keychain is locked.",
                comment: "Clipboard banner when the login keychain is locked")
        case .keychainUnavailable:
            LocalizedStringResource(
                "Pounce cannot read the clipboard history key from the keychain. Nothing was deleted.",
                comment: "Clipboard banner when the keychain denied access to the key")
        case .accessDenied:
            LocalizedStringResource(
                "Pounce is not allowed to read the clipboard, so nothing is recorded.",
                comment: "Clipboard banner when pasteboard access is denied in Privacy settings")
        case .accessAsks:
            LocalizedStringResource(
                "macOS asks before Pounce reads the clipboard, so nothing is recorded. Allow Pounce in Privacy & Security to record.",
                comment: "Clipboard banner when pasteboard access is set to ask each time")
        case .paused:
            LocalizedStringResource("Recording is paused.", comment: "Clipboard banner when recording is paused")
        case .historyReset:
            LocalizedStringResource(
                "The history key was missing, so a new, empty history was started. The old history stays encrypted and is deleted automatically after 30 days.",
                comment: "Clipboard banner after the history was reset because its key was missing")
        case .pasteDisabled:
            LocalizedStringResource(
                "Return copies. Allow Accessibility to paste into the previous app.",
                comment: "Clipboard banner when Accessibility is not granted")
        }
    }
}

struct ClipboardBannerRow: View {
    let banner: ClipboardBanner
    let actions: ClipboardActions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: banner.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(banner.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            button
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var button: some View {
        switch banner {
        case .keychainLocked, .keychainUnavailable:
            Button {
                actions.retry()
            } label: {
                Text("Try Again", comment: "Button that retries opening the clipboard history")
            }
        case .accessDenied, .accessAsks:
            Button {
                actions.openPasteboardSettings()
            } label: {
                Text("Open Privacy Settings", comment: "Button that opens Privacy & Security settings")
            }
        case .paused:
            Button {
                actions.resume()
            } label: {
                Text("Resume", comment: "Button that resumes clipboard recording")
            }
        case .historyReset:
            Button {
                actions.dismissReset()
            } label: {
                Text("Dismiss", comment: "Button that dismisses a notice")
            }
        case .pasteDisabled:
            Button {
                actions.openAccessibilitySettings()
            } label: {
                Text("Open Accessibility Settings", comment: "Button that opens Accessibility privacy settings")
            }
        }
    }
}

/// Shown when the history is empty (no query, no filter).
struct ClipboardEmptyView: View {
    let state: ClipboardState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No clipboard history yet", comment: "Empty state title of the clipboard history")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var message: LocalizedStringResource {
        state.isRecording
            ? LocalizedStringResource(
                "Copy something and it appears here. Passwords and ignored apps are never recorded.",
                comment: "Empty state message of the clipboard history while recording")
            : LocalizedStringResource(
                "Recording is off, so nothing new is added.",
                comment: "Empty state message of the clipboard history while not recording")
    }
}

/// The preview beside the list: the full entry, loaded off the main actor, and its details.
struct ClipPreview: View {
    let id: Int64?
    let load: @Sendable (Int64) async -> ClipDetail?

    @State private var detail: ClipDetail?
    @State private var loadedID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let detail, detail.summary.id == id {
                content(detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                ClipMetadata(summary: detail.summary)
            } else if loadedID == id, id != nil {
                Text("This entry is no longer in the history.", comment: "Clipboard preview of a deleted entry")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .padding(12)
        .task(id: id) {
            guard let id else {
                detail = nil
                loadedID = nil
                return
            }
            let loaded = await load(id)
            guard !Task.isCancelled else { return }
            detail = loaded
            loadedID = id
        }
    }

    @ViewBuilder
    private func content(_ detail: ClipDetail) -> some View {
        switch detail.summary.kind {
        case .image:
            if let image = ClipPreviewContent.image(detail) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(ClipKind.image.title))
            } else {
                Text(ClipKind.image.title).foregroundStyle(.secondary)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ClipPreviewContent.paths(detail), id: \.self) { path in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(filePath: path).lastPathComponent)
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: "doc")
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text, .rich, .url:
            ScrollView {
                Text(detail.previewText)
                    .font(detail.summary.kind == .text ? .body.monospaced() : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Kind, source app, time and size of an entry.
struct ClipMetadata: View {
    let summary: ClipSummary

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            row(Text("Type", comment: "Clipboard preview label"), Text(summary.kind.title))
            if let app = summary.sourceAppName, !app.isEmpty {
                row(Text("Copied from", comment: "Clipboard preview label of the source app"), Text(app))
            }
            row(
                Text("Copied", comment: "Clipboard preview label of the capture time"),
                Text(summary.createdAt, format: .dateTime.day().month().hour().minute())
            )
            row(
                Text("Size", comment: "Clipboard preview label"),
                Text(Int64(summary.byteSize), format: .byteCount(style: .memory))
            )
        }
        .font(.caption)
    }

    private func row(_ label: Text, _ value: Text) -> some View {
        GridRow {
            label.foregroundStyle(.secondary)
            value.lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Pure helpers for the preview (tested).
enum ClipPreviewContent {
    static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic"]

    static func image(_ detail: ClipDetail) -> NSImage? {
        for item in detail.items {
            for type in imageTypes {
                if let data = item.data(for: type), let image = NSImage(data: data) {
                    return image
                }
            }
        }
        return nil
    }

    static func paths(_ detail: ClipDetail) -> [String] {
        detail.previewText.split(separator: "\n").map(String.init)
    }
}

/// The first-launch step: what is recorded, what never is, and the controls.
struct ClipboardOnboardingView: View {
    let state: ClipboardState
    let actions: ClipboardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Pounce keeps what you copy so you can paste it again with ⌘⇧V. The history stays on this Mac, encrypted, for 30 days or 1000 entries.",
                comment: "Clipboard onboarding text"
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "In Chrome, Slack and Google Docs ⌘⇧V means “paste without formatting”. Pounce takes this shortcut over; you can change it in Settings.",
                comment: "Clipboard onboarding note about the shortcut conflict"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Label {
                Text(
                    "Passwords, concealed content and apps like password managers are never recorded. You can pause recording from the menu bar.",
                    comment: "Clipboard onboarding text about privacy"
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .accessibilityHidden(true)
            }
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "To paste into the app you were using, Pounce needs Accessibility. Without it, Return copies the entry and you paste with ⌘V.",
                        comment: "Clipboard onboarding text about Accessibility"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    if state.pasteAllowed {
                        Label {
                            Text("Accessibility is allowed.", comment: "Clipboard onboarding status")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                        }
                    } else {
                        Button {
                            actions.openAccessibilitySettings()
                        } label: {
                            Text(
                                "Open Accessibility Settings",
                                comment: "Button that opens Accessibility privacy settings")
                        }
                    }
                }
            } icon: {
                Image(systemName: "keyboard")
                    .accessibilityHidden(true)
            }
        }
    }
}

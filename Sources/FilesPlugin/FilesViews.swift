import LintelKit
import LintelUI
import SwiftUI

/// The Full Disk Access step, shown before the first scan (spec: Onboarding, Faza 3). Leaving it
/// (Continue, Done or closing the window) starts indexing with whatever access Lintel has.
/// The `files.fullDiskAccess` welcome page's controls (prototype `shell-welcome-*`): the explanation is the
/// step's `text`, this view is the Full Disk Access part and the note. Nothing is asked: the buttons only open
/// System Settings and re-read the state.
struct FilesOnboardingView: View {
    let model: FilesViewModel

    static let text = LocalizedStringResource(
        "Lintel finds files and folders by name, using its own index that stays on this Mac. It never reads what is inside your files.",
        comment: "File search onboarding text")

    var body: some View {
        WelcomeStepColumn {
            WelcomeStepItem(
                Text(
                    "With Full Disk Access, Lintel also searches Desktop, Documents, Downloads and iCloud Drive. Without it, those folders are skipped so macOS does not ask about each one. You can add them one at a time in Settings.",
                    comment: "File search onboarding text about Full Disk Access"),
                isDone: model.state.fullDiskAccess == .granted,
                doneText: Text("Full Disk Access is allowed.", comment: "Full Disk Access status")
            ) {
                AccessStatusLabel(status: model.state.fullDiskAccess)
                HStack {
                    Button {
                        model.openAccessSettings()
                    } label: {
                        Text("Open Privacy Settings…", comment: "Button that opens the Full Disk Access settings")
                    }
                    Button {
                        model.checkAccess()
                    } label: {
                        Text("Check Again", comment: "Button that re-reads the Full Disk Access state")
                    }
                }
            }
            WelcomeStepNote(
                Text(
                    "Indexing starts when you continue. Folders like node_modules, .git, caches and ~/Library are left out.",
                    comment: "File search onboarding note"))
        }
        .onAppear { model.checkAccess() }
        .onDisappear { model.completeSetup() }
    }
}

/// Full Disk Access granted or not, with a symbol so the state never depends on colour alone.
struct AccessStatusLabel: View {
    let status: PermissionStatus

    var body: some View {
        if status == .granted {
            Label {
                Text("Full Disk Access is allowed.", comment: "Full Disk Access status")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LintelBrand.statusOk)
                    .accessibilityHidden(true)
            }
        } else {
            Label {
                Text("Full Disk Access is not allowed.", comment: "Full Disk Access status")
            } icon: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(LintelBrand.secondaryText)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct IndexStatusText: View {
    let status: IndexStatus
    let setupCompleted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch status.phase {
            case .waiting:
                if setupCompleted {
                    Text("Not running", comment: "File index status")
                } else {
                    Text("Waiting for setup", comment: "File index status before the first scan")
                }
            case .loading:
                Text("Loading…", comment: "File index status while the saved index loads")
            case .scanning:
                Text("Indexing… \(status.count.formatted())", comment: "File index status while scanning; item count")
            case .ready:
                Text("\(status.count.formatted()) items indexed", comment: "File index status; item count")
            }
        }
        .monospacedDigit()
    }
}

struct ProtectedFolderRow: View {
    let folder: ProtectedFolder
    let home: String
    let hasAccess: Bool
    let isIndexed: Bool
    let isAdded: Bool
    let includesICloudDrive: Bool
    let setAdded: (Bool) -> Void
    let setICloudDrive: (Bool) -> Void

    var body: some View {
        LabeledContent {
            if hasAccess {
                if folder == .iCloudDrive {
                    Toggle(isOn: Binding(get: { includesICloudDrive }, set: setICloudDrive)) {
                        Text(folder.title)
                    }
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            } else if isAdded {
                Button {
                    setAdded(false)
                } label: {
                    Text("Remove", comment: "Button that removes the selected item from a list")
                }
                .accessibilityLabel(
                    Text(
                        "Remove \(String(localized: folder.title))",
                        comment: "Accessibility label of the button that stops searching a protected folder"))
            } else {
                Button {
                    setAdded(true)
                } label: {
                    Text("Add", comment: "Button that adds an item to a list")
                }
                .accessibilityLabel(
                    Text(
                        "Add \(String(localized: folder.title))",
                        comment: "Accessibility label of the button that searches a protected folder"))
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.title)
                    Group {
                        if isIndexed {
                            Text("Searched", comment: "Protected folder state")
                        } else {
                            Text("Not searched", comment: "Protected folder state")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(LintelBrand.secondaryText)
                }
            } icon: {
                Image(systemName: folder == .iCloudDrive ? "icloud" : "folder")
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
        }
    }
}

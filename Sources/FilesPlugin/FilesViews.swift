import AppKit
import PounceKit
import SwiftUI

/// The Full Disk Access step, shown before the first scan (spec: Onboarding, Faza 3). Leaving it
/// (Continue, Done or closing the window) starts indexing with whatever access Pounce has.
struct FilesOnboardingView: View {
    let model: FilesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Pounce finds files and folders by name, using its own index that stays on this Mac. It never reads what is inside your files.",
                comment: "File search onboarding text"
            )
            .fixedSize(horizontal: false, vertical: true)
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "With Full Disk Access, Pounce also searches Desktop, Documents, Downloads and iCloud Drive. Without it, those folders are skipped so macOS does not ask about each one. You can add them one at a time in Settings.",
                        comment: "File search onboarding text about Full Disk Access"
                    )
                    .fixedSize(horizontal: false, vertical: true)
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
            } icon: {
                Image(systemName: "hand.raised")
                    .accessibilityHidden(true)
            }
            Text(
                "Indexing starts when you continue. Folders like node_modules, .git, caches and ~/Library are left out.",
                comment: "File search onboarding note"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        } else {
            Label {
                Text("Full Disk Access is not allowed.", comment: "Full Disk Access status")
            } icon: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Settings → Files: index status, Full Disk Access, protected folders, roots and exclusions.
struct FilesSettingsPane: View {
    let model: FilesViewModel

    @State private var selectedRoot: String?
    @State private var selectedExclusion: String?
    @State private var newExclusion = ""
    @State private var confirmsRebuild = false

    private var state: FilesState { model.state }
    private var settings: FilesSettings { model.settings }
    private var hasAccess: Bool { state.fullDiskAccess == .granted }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if settings.setupCompleted {
                        Button {
                            confirmsRebuild = true
                        } label: {
                            Text("Rebuild Index…", comment: "Button that deletes the file index and scans again")
                        }
                        .disabled(state.status.phase != .ready)
                    } else {
                        Button {
                            model.completeSetup()
                        } label: {
                            Text("Start Indexing", comment: "Button that starts the first file scan")
                        }
                    }
                } label: {
                    IndexStatusText(status: state.status, setupCompleted: settings.setupCompleted)
                }
            } header: {
                Text("Index", comment: "Settings section title")
            }

            Section {
                AccessStatusLabel(status: state.fullDiskAccess)
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
                ForEach(ProtectedFolder.allCases, id: \.self) { folder in
                    ProtectedFolderRow(
                        folder: folder,
                        home: settings.home,
                        hasAccess: hasAccess,
                        isIndexed: state.plan?.indexedProtected.contains(folder)
                            ?? (hasAccess || settings.addedProtected.contains(folder)),
                        isAdded: settings.addedProtected.contains(folder),
                        includesICloudDrive: settings.includesICloudDrive,
                        setAdded: { settings.setProtected(folder, added: $0) },
                        setICloudDrive: { settings.setIncludesICloudDrive($0) }
                    )
                }
            } header: {
                Text("Full Disk Access", comment: "Settings section title")
            } footer: {
                if !hasAccess {
                    Text(
                        "Without Full Disk Access, adding a folder here makes macOS ask once for that folder.",
                        comment: "Settings footer of the protected folders"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                List(selection: $selectedRoot) {
                    ForEach(settings.displayedRoots, id: \.self) { root in
                        Label {
                            Text(
                                PathText.abbreviate(
                                    PathText.expand(root, home: settings.home) ?? root, home: settings.home)
                            )
                            .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "folder")
                                .accessibilityHidden(true)
                        }
                        .tag(root)
                    }
                }
                .frame(minHeight: 90)
                .accessibilityLabel(Text("Searched folders", comment: "Settings section title"))
                HStack {
                    Button {
                        addRoot()
                    } label: {
                        Text("Add Folder…", comment: "Button that adds a folder to the file index")
                    }
                    Button {
                        if let selectedRoot {
                            settings.removeRoot(selectedRoot)
                            self.selectedRoot = nil
                        }
                    } label: {
                        Text("Remove", comment: "Button that removes the selected item from a list")
                    }
                    .disabled(selectedRoot == nil)
                    Spacer()
                    Button {
                        settings.restoreDefaultRoots()
                    } label: {
                        Text("Restore Defaults", comment: "Button that restores the default searched folders")
                    }
                    .disabled(settings.usesDefaultRoots)
                }
            } header: {
                Text("Searched folders", comment: "Settings section title")
            }

            Section {
                List(selection: $selectedExclusion) {
                    ForEach(settings.exclusions, id: \.self) { entry in
                        Text(entry).tag(entry)
                    }
                }
                .frame(minHeight: 70)
                .accessibilityLabel(Text("Exclusions", comment: "Settings section title"))
                HStack {
                    TextField(
                        text: $newExclusion,
                        prompt: Text("Name, *.pattern or ~/path", comment: "Placeholder of the new exclusion field")
                    ) {
                        Text("New exclusion", comment: "Accessibility label of the new exclusion field")
                    }
                    .onSubmit(addExclusion)
                    Button(action: addExclusion) {
                        Text("Add", comment: "Button that adds an item to a list")
                    }
                    .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        if let selectedExclusion {
                            settings.removeExclusion(selectedExclusion)
                            self.selectedExclusion = nil
                        }
                    } label: {
                        Text("Remove", comment: "Button that removes the selected item from a list")
                    }
                    .disabled(selectedExclusion == nil)
                }
                Toggle(isOn: Binding(get: { settings.includesHidden }, set: { settings.setIncludesHidden($0) })) {
                    Text("Include hidden files", comment: "Settings toggle that indexes hidden files")
                }
            } header: {
                Text("Exclusions", comment: "Settings section title")
            } footer: {
                Text(
                    "Always left out: ~/Library, node_modules, .git, DerivedData and cache folders.",
                    comment: "Settings footer listing the default exclusions"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.checkAccess() }
        .confirmationDialog(
            Text("Rebuild the file index?", comment: "Rebuild confirmation title"),
            isPresented: $confirmsRebuild
        ) {
            Button {
                model.rebuild()
            } label: {
                Text("Rebuild Index", comment: "Confirmation button that rebuilds the file index")
            }
        } message: {
            Text(
                "Pounce scans the searched folders again. Results stay available while it runs.",
                comment: "Rebuild confirmation message"
            )
        }
    }

    private func addExclusion() {
        settings.addExclusion(newExclusion)
        newExclusion = ""
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add", comment: "Button that adds an item to a list")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.addRoot(url.path)
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
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: folder == .iCloudDrive ? "icloud" : "folder")
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
        }
    }
}

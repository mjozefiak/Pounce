import AppKit
import LintelKit
import SwiftUI

/// Settings → Files in the old window (`.legacyWindow`), unchanged from before the main window: index status,
/// Full Disk Access, protected folders, roots and exclusions. Removed with the old window in step 6.3b.
struct LegacyFilesSettingsPane: View {
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
                "Lintel scans the searched folders again. Results stay available while it runs.",
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

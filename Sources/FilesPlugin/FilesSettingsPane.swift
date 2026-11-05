import AppKit
import LintelKit
import LintelUI
import SwiftUI

/// Settings → Files: `FilesPaneContent` on the `SettingsPane` template (prototype `set-files`, spec step 4.3).
/// The banner is the host's, from `FilesPlugin.settingsStatus`.
struct FilesSettingsPane: View {
    let model: FilesViewModel

    /// The Rebuild question.
    static let rebuildConfirmation = DestructiveConfirmation(
        prompt: LocalizedStringResource("Rebuild the file index?", comment: "Rebuild confirmation title"),
        detail: LocalizedStringResource(
            "Lintel scans the searched folders again. Results stay available while it runs.",
            comment: "Rebuild confirmation message"),
        confirmTitle: LocalizedStringResource(
            "Rebuild Index", comment: "Confirmation button that rebuilds the file index"))

    var body: some View {
        FilesPaneContent(model: model)
    }
}

/// The Files pane (prototype `set-files`): Basics (Folders to index, Include iCloud Drive),
/// Advanced (the searched folders, the protected folders, exclusions, hidden files) and Data (the index with
/// Rebuild…). Indexing is started from the banner.
struct FilesPaneContent: View {
    let model: FilesViewModel

    @Environment(\.lintelTextSize) private var textSize
    @State private var newExclusion = ""
    @State private var confirmsRebuild = false

    private var state: FilesState { model.state }
    private var settings: FilesSettings { model.settings }
    private var hasAccess: Bool { state.fullDiskAccess == .granted }

    var body: some View {
        SettingsPane {
            Section {
                LabeledContent {
                    Button(action: addRoot) {
                        Text("Add Folder…", comment: "Button that adds a folder to the file index")
                            .font(textSize.font(.body))
                    }
                } label: {
                    Text("Folders to index", comment: "Settings → Files: label of the searched folders row")
                        .font(textSize.font(.body))
                    rootsSummary
                        .font(textSize.font(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Toggle(isOn: iCloudDriveBinding) {
                    Text("Include iCloud Drive", comment: "Settings → Files: switch that indexes iCloud Drive")
                        .font(textSize.font(.body))
                    if !hasAccess {
                        Text(
                            "Without Full Disk Access, macOS asks once for this folder.",
                            comment: "Settings → Files: help under Include iCloud Drive without Full Disk Access"
                        )
                        .font(textSize.font(.callout))
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Basics", comment: "Settings pane section title: the main settings of a pane")
                    .settingsSectionHeader()
            }
        } advanced: {
            SearchedRootsRows(settings: settings)
            ProtectedFoldersRows(
                settings: settings, hasAccess: hasAccess, indexed: state.plan?.indexedProtected)
            ExclusionRows(settings: settings, newExclusion: $newExclusion)
            Toggle(isOn: Binding(get: { settings.includesHidden }, set: { settings.setIncludesHidden($0) })) {
                Text("Include hidden files", comment: "Settings toggle that indexes hidden files")
                    .font(textSize.font(.body))
            }
            .toggleStyle(.switch)
            SettingsFooter(
                LocalizedStringResource(
                    "Always left out: ~/Library, node_modules, .git, DerivedData and cache folders.",
                    comment: "Settings footer listing the default exclusions"))
        } data: {
            LabeledContent {
                Button {
                    confirmsRebuild = true
                } label: {
                    Text("Rebuild…", comment: "Settings → Files: button that deletes the file index and scans again")
                        .font(textSize.font(.body))
                }
                .disabled(!settings.setupCompleted || state.status.phase != .ready)
            } label: {
                Text("Index", comment: "Settings section title")
                    .font(textSize.font(.body))
                indexDetail
                    .font(textSize.font(.callout))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .onAppear { model.checkAccess() }
        .destructiveConfirmation(isPresented: $confirmsRebuild, FilesSettingsPane.rebuildConfirmation) {
            model.rebuild()
        }
    }

    /// "Home folder and Applications" for the defaults, else the folders themselves.
    private var rootsSummary: Text {
        if settings.usesDefaultRoots {
            return Text("Home folder and Applications", comment: "Settings → Files: the default searched folders")
        }
        let home = settings.home
        let homeName = String(localized: "Home folder", comment: "Settings → Files: the home folder in the folder list")
        let paths = settings.displayedRoots.map { root -> String in
            let expanded = PathText.expand(root, home: home) ?? root
            return expanded == home ? homeName : PathText.abbreviate(expanded, home: home)
        }
        return Text(verbatim: ListFormatter.localizedString(byJoining: paths))
    }

    /// The state of the index, in the old pane's words; "Not built yet" before the first scan.
    private var indexDetail: Text {
        guard settings.setupCompleted else {
            return Text("Not built yet", comment: "Settings → Files: the index before the first scan")
        }
        switch state.status.phase {
        case .waiting, .loading:
            return Text("Loading…", comment: "File index status while the saved index loads")
        case .scanning:
            return Text(
                "Indexing… \(state.status.count.formatted())", comment: "File index status while scanning; item count")
        case .ready:
            return Text("\(state.status.count.formatted()) items indexed", comment: "File index status; item count")
        }
    }

    /// With Full Disk Access iCloud Drive is on unless switched off (`plugins.files.icloud`); without it, it is
    /// one of the folders added one at a time (`plugins.files.protectedFolders`), as in the old pane.
    private var iCloudDriveBinding: Binding<Bool> {
        let settings = settings
        if hasAccess {
            return Binding(get: { settings.includesICloudDrive }, set: { settings.setIncludesICloudDrive($0) })
        }
        return Binding(
            get: { settings.addedProtected.contains(.iCloudDrive) },
            set: { settings.setProtected(.iCloudDrive, added: $0) })
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

/// The searched folders, each with Remove, and Restore Defaults.
struct SearchedRootsRows: View {
    let settings: FilesSettings

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Text("Searched folders", comment: "Settings section title")
            .font(textSize.font(.body))
        ForEach(settings.displayedRoots, id: \.self) { root in
            let display = PathText.abbreviate(PathText.expand(root, home: settings.home) ?? root, home: settings.home)
            LabeledContent {
                Button {
                    settings.removeRoot(root)
                } label: {
                    Text("Remove", comment: "Button that removes the selected item from a list")
                        .font(textSize.font(.body))
                }
                .accessibilityLabel(
                    Text("Remove \(display)", comment: "Accessibility label of the button that removes a list item"))
            } label: {
                Label {
                    Text(verbatim: display)
                        .font(textSize.font(.callout))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                        .font(textSize.font(.callout))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        Button {
            settings.restoreDefaultRoots()
        } label: {
            Text("Restore Defaults", comment: "Button that restores the default searched folders")
                .font(textSize.font(.body))
        }
        .disabled(settings.usesDefaultRoots)
    }
}

/// Desktop, Documents and Downloads: searched with Full Disk Access, else added one at a time.
struct ProtectedFoldersRows: View {
    let settings: FilesSettings
    let hasAccess: Bool
    let indexed: Set<ProtectedFolder>?

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        ForEach(ProtectedFolder.allCases.filter { $0 != .iCloudDrive }, id: \.self) { folder in
            let isAdded = settings.addedProtected.contains(folder)
            let isIndexed = indexed?.contains(folder) ?? (hasAccess || isAdded)
            LabeledContent {
                if !hasAccess {
                    Button {
                        settings.setProtected(folder, added: !isAdded)
                    } label: {
                        if isAdded {
                            Text("Remove", comment: "Button that removes the selected item from a list")
                                .font(textSize.font(.body))
                        } else {
                            Text("Add", comment: "Button that adds an item to a list")
                                .font(textSize.font(.body))
                        }
                    }
                    .accessibilityLabel(
                        isAdded
                            ? Text(
                                "Remove \(String(localized: folder.title))",
                                comment: "Accessibility label of the button that stops searching a protected folder")
                            : Text(
                                "Add \(String(localized: folder.title))",
                                comment: "Accessibility label of the button that searches a protected folder"))
                }
            } label: {
                Text(folder.title)
                    .font(textSize.font(.body))
                Group {
                    if isIndexed {
                        Text("Searched", comment: "Protected folder state")
                    } else {
                        Text("Not searched", comment: "Protected folder state")
                    }
                }
                .font(textSize.font(.callout))
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// The user's exclusions, each with Remove, and the field that adds one.
struct ExclusionRows: View {
    let settings: FilesSettings
    @Binding var newExclusion: String

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Text("Exclusions", comment: "Settings section title")
            .font(textSize.font(.body))
        ForEach(settings.exclusions, id: \.self) { entry in
            LabeledContent {
                Button {
                    settings.removeExclusion(entry)
                } label: {
                    Text("Remove", comment: "Button that removes the selected item from a list")
                        .font(textSize.font(.body))
                }
                .accessibilityLabel(
                    Text("Remove \(entry)", comment: "Accessibility label of the button that removes a list item"))
            } label: {
                Text(verbatim: entry)
                    .font(textSize.font(.callout))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        HStack {
            TextField(
                text: $newExclusion,
                prompt: Text("Name, *.pattern or ~/path", comment: "Placeholder of the new exclusion field")
            ) {
                Text("New exclusion", comment: "Accessibility label of the new exclusion field")
            }
            .font(textSize.font(.body))
            .labelsHidden()
            .onSubmit(add)
            Button(action: add) {
                Text("Add", comment: "Button that adds an item to a list")
                    .font(textSize.font(.body))
            }
            .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        settings.addExclusion(newExclusion)
        newExclusion = ""
    }
}

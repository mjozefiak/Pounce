import Foundation
import Observation
import PounceKit

/// The file plugin's settings under `plugins.files.` (a protected contract, `BACKWARD_COMPATIBILITY.md`
/// section 3), with a change callback for the plugin.
@MainActor @Observable
final class FilesSettings {
    enum Key {
        /// `[String]`: index roots (absolute or `~/…`); missing or empty means the home folder and
        /// `/Applications`.
        static let roots = "roots"
        /// `[String]`: the user's exclusions: paths (`/…`, `~/…`), names, or wildcard patterns (`*.log`).
        static let exclusions = "exclusions"
        /// `[String]` of `ProtectedFolder` raw values (`desktop`, `documents`, `downloads`, `icloud`) the
        /// user added one at a time, indexed even without Full Disk Access.
        static let protectedFolders = "protectedFolders"
        /// `Bool`, default `true`: with Full Disk Access, iCloud Drive is indexed.
        static let iCloudDrive = "icloud"
        /// `Bool`, default `false`: hidden items (a leading dot or the hidden flag) are indexed.
        static let includesHidden = "includeHidden"
        /// `Bool`, default `false`: the Full Disk Access step was finished or skipped (or indexing was started
        /// from Settings), so the first scan may run.
        static let setupCompleted = "setupCompleted"
        /// `Bool`, default `false`: the panel's "no Full Disk Access" notice was dismissed.
        static let accessNoticeDismissed = "accessNoticeDismissed"
        /// DEBUG builds only, QA mode: a fake home folder (protected folders and `~` are resolved against it),
        /// so a QA run never touches the tester's real folders (`docs/qa.md`).
        static let qaHome = "qaHome"
    }

    @ObservationIgnored private let store: PluginSettings
    @ObservationIgnored var onChange: () -> Void = {}

    private(set) var configuredRoots: [String]?
    private(set) var exclusions: [String]
    private(set) var addedProtected: Set<ProtectedFolder>
    private(set) var includesICloudDrive: Bool
    private(set) var includesHidden: Bool
    private(set) var setupCompleted: Bool
    private(set) var accessNoticeDismissed: Bool
    /// The home folder all `~` paths refer to.
    let home: String

    init(_ store: PluginSettings, realHome: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.store = store
        let roots = store.stringArray(Key.roots) ?? store.string(Key.roots).map { [$0] }
        configuredRoots = (roots?.isEmpty ?? true) ? nil : roots
        exclusions = store.stringArray(Key.exclusions) ?? []
        addedProtected = Set((store.stringArray(Key.protectedFolders) ?? []).compactMap(ProtectedFolder.init))
        includesICloudDrive = store.bool(Key.iCloudDrive, default: true)
        includesHidden = store.bool(Key.includesHidden, default: false)
        setupCompleted = store.bool(Key.setupCompleted, default: false)
        accessNoticeDismissed = store.bool(Key.accessNoticeDismissed, default: false)
        #if DEBUG
        home = store.string(Key.qaHome).flatMap { PathText.expand($0, home: realHome) } ?? realHome
        #else
        home = realHome
        #endif
    }

    /// The roots as the user sees them (defaults included).
    var displayedRoots: [String] {
        configuredRoots ?? RootPlanner.defaultRoots(home: home)
    }

    var usesDefaultRoots: Bool { configuredRoots == nil }

    func rules() -> IgnoreRules {
        IgnoreRules.make(home: home, userExclusions: exclusions, includesHidden: includesHidden)
    }

    func plan(fullDiskAccess: Bool) -> IndexPlan {
        RootPlanner.plan(
            configuredRoots: configuredRoots,
            home: home,
            fullDiskAccess: fullDiskAccess,
            addedProtected: addedProtected,
            includesICloudDrive: includesICloudDrive,
            rules: rules()
        )
    }

    // MARK: Changes

    func addRoot(_ path: String) {
        guard let expanded = PathText.expand(path, home: home) else { return }
        let display = PathText.abbreviate(expanded, home: home)
        let current = displayedRoots.map { PathText.abbreviate(PathText.expand($0, home: home) ?? $0, home: home) }
        guard !current.contains(display) else { return }
        setRoots(displayedRoots + [display])
    }

    func removeRoot(_ path: String) {
        setRoots(displayedRoots.filter { $0 != path })
    }

    func restoreDefaultRoots() {
        configuredRoots = nil
        store.removeValue(for: Key.roots)
        onChange()
    }

    private func setRoots(_ roots: [String]) {
        configuredRoots = roots.isEmpty ? nil : roots
        if roots.isEmpty {
            store.removeValue(for: Key.roots)
        } else {
            store.set(roots, for: Key.roots)
        }
        onChange()
    }

    func addExclusion(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !exclusions.contains(trimmed) else { return }
        exclusions.append(trimmed)
        store.set(exclusions, for: Key.exclusions)
        onChange()
    }

    func removeExclusion(_ entry: String) {
        exclusions.removeAll { $0 == entry }
        store.set(exclusions, for: Key.exclusions)
        onChange()
    }

    func setProtected(_ folder: ProtectedFolder, added: Bool) {
        if added {
            addedProtected.insert(folder)
        } else {
            addedProtected.remove(folder)
        }
        store.set(ProtectedFolder.allCases.filter(addedProtected.contains).map(\.rawValue), for: Key.protectedFolders)
        onChange()
    }

    func setIncludesICloudDrive(_ value: Bool) {
        includesICloudDrive = value
        store.set(value, for: Key.iCloudDrive)
        onChange()
    }

    func setIncludesHidden(_ value: Bool) {
        includesHidden = value
        store.set(value, for: Key.includesHidden)
        onChange()
    }

    func completeSetup() {
        guard !setupCompleted else { return }
        setupCompleted = true
        store.set(true, for: Key.setupCompleted)
        onChange()
    }

    func dismissAccessNotice() {
        accessNoticeDismissed = true
        store.set(true, for: Key.accessNoticeDismissed)
        onChange()
    }
}

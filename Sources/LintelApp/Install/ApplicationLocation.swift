import Foundation

/// Where the running app bundle lives, decided from its URL alone (spec `2026-11-19-updates-and-open-source-hygiene`, step 4.2).
/// An app outside the Applications folders (a mounted disk image, an App Translocation path, Downloads) cannot
/// update itself, so the shell offers to move it.
nonisolated enum ApplicationLocation: Equatable, Sendable {
    /// Inside one of the allowed folders (`/Applications`, `~/Applications`), directly or in a subfolder.
    case applications
    /// A randomized read-only path Gatekeeper runs a quarantined app from
    /// (`/private/var/folders/…/AppTranslocation/<UUID>/d/Lintel.app`).
    case translocated
    /// A mounted volume, usually the disk image (`/Volumes/Lintel/Lintel.app`).
    case mountedVolume
    /// Anywhere else: Downloads, the Desktop, a build folder.
    case elsewhere

    /// Whether the shell offers to move the app to Applications.
    var offersMove: Bool { self != .applications }

    /// The name of the installed bundle.
    static let bundleName = "Lintel.app"

    /// `/Applications` and `~/Applications`.
    static func allowedFolders(home: URL) -> [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// Where Move puts the bundle: `/Applications/Lintel.app`.
    static let destination = URL(filePath: "/Applications", directoryHint: .isDirectory)
        .appending(path: bundleName, directoryHint: .isDirectory)

    /// Classifies `bundleURL`.
    /// - Parameters:
    ///   - allowedFolders: folders the app may run from without an offer.
    ///   - resolveSymlinks: resolves symbolic links in a path. A bundle counts as inside an allowed folder when
    ///     either form of its path is inside either form of the folder's path, so a symlinked Applications folder
    ///     (or `/Volumes/Macintosh HD`, a link to `/`) is recognized. Tests pass a table instead of the disk.
    static func classify(
        bundleURL: URL, allowedFolders: [URL],
        resolveSymlinks: (URL) -> URL = { $0.resolvingSymlinksInPath() }
    ) -> ApplicationLocation {
        let raw = bundleURL.standardizedFileURL
        let resolved = resolveSymlinks(raw).standardizedFileURL
        let bundlePaths = [raw.path, resolved.path]
        // A translocated bundle is checked first: its path is never one the user chose.
        if bundlePaths.contains(where: isTranslocated) { return .translocated }
        let folderPaths = allowedFolders.flatMap { folder in
            let folder = folder.standardizedFileURL
            return [folder.path, resolveSymlinks(folder).standardizedFileURL.path]
        }
        for bundle in bundlePaths where folderPaths.contains(where: { isInside(bundle, folder: $0) }) {
            return .applications
        }
        if bundlePaths.allSatisfy({ isInside($0, folder: "/Volumes") }) { return .mountedVolume }
        return .elsewhere
    }

    /// `…/AppTranslocation/…` anywhere in the path (Gatekeeper uses `/private/var/folders/<x>/<y>/T/AppTranslocation`).
    private static func isTranslocated(_ path: String) -> Bool {
        path.split(separator: "/").contains("AppTranslocation")
    }

    /// `path` is `folder` itself or below it, compared by whole components.
    private static func isInside(_ path: String, folder: String) -> Bool {
        let folderComponents = folder.split(separator: "/")
        let components = path.split(separator: "/")
        return components.count > folderComponents.count
            && Array(components.prefix(folderComponents.count)) == folderComponents
    }
}

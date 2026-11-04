import Foundation
import os

/// What the settings migration needs from `UserDefaults`; tests pass a dictionary instead, because a real
/// `UserDefaults` suite leaves a plist in `~/Library/Preferences`.
nonisolated protocol DefaultsAccess {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: DefaultsAccess {}

/// One-time move of what the app kept under its previous name, so renaming the app loses nothing.
///
/// - **Folders.** `Application Support/<old name>` and `Caches/<old name>` become `Application Support/Lintel`
///   and `Caches/Lintel`: one `moveItem` (an atomic rename on the same volume), before anything creates the new
///   folder. If both exist and the new one holds anything, nothing is merged or deleted.
/// - **Settings.** The `UserDefaults` domain follows the bundle identifier, so the old settings would be
///   invisible to the renamed app. The keys keep their names; this copies every `app.*`, `plugins.*` and
///   `KeyboardShortcuts_*` value that the new domain does not have yet, and then never runs again.
///
/// The Keychain keys are not handled here: `MasterKeyStore` copies each key from its old service name when it
/// first needs it. Permissions (Accessibility, Full Disk Access, microphone) belong to the bundle identifier
/// and cannot be carried over; the system asks again.
nonisolated struct LegacyDataMigration {
    static let legacyFolderName = "Pounce"  // LEGACY-POUNCE
    static let currentFolderName = "Lintel"
    static let legacyDefaultsDomain = "app.pounce.Pounce"  // LEGACY-POUNCE
    /// `app.*` is a protected namespace; this marker only says that the copy has happened.
    static let migratedKey = "app.legacyDefaultsMigrated"
    static let copiedPrefixes = ["app.", "plugins.", "KeyboardShortcuts_"]

    enum FolderOutcome: Equatable {
        case nothingToMove
        case moved
        /// The old and the new folder both hold data: nothing was touched.
        case bothExist
        case failed
    }

    var fileManager: FileManager = .default
    var logger = Logger(subsystem: "com.lintelapp", category: "migration")

    /// Runs the whole migration for the live app.
    func run(
        supportDirectory: URL,
        cachesDirectory: URL,
        defaults: any DefaultsAccess = UserDefaults.standard,
        legacyDefaults: [String: Any]? = UserDefaults.standard.persistentDomain(
            forName: LegacyDataMigration.legacyDefaultsDomain)
    ) {
        let data = migrateFolder(
            legacy: supportDirectory.appending(path: Self.legacyFolderName, directoryHint: .isDirectory),
            current: supportDirectory.appending(path: Self.currentFolderName, directoryHint: .isDirectory))
        let caches = migrateFolder(
            legacy: cachesDirectory.appending(path: Self.legacyFolderName, directoryHint: .isDirectory),
            current: cachesDirectory.appending(path: Self.currentFolderName, directoryHint: .isDirectory))
        let copied = migrateDefaults(legacy: legacyDefaults, into: defaults)
        if data != .nothingToMove || caches != .nothingToMove || copied > 0 {
            logger.info(
                "Legacy data: folder \(String(describing: data), privacy: .public), caches \(String(describing: caches), privacy: .public), \(copied) settings copied"
            )
        }
    }

    func migrateFolder(legacy: URL, current: URL) -> FolderOutcome {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .nothingToMove
        }
        if fileManager.fileExists(atPath: current.path) {
            // An empty folder holds nothing worth keeping, so the old one can take its place.
            guard isEmptyDirectory(current) else { return .bothExist }
            do {
                try fileManager.removeItem(at: current)
            } catch {
                logger.error("Cannot replace the empty new folder: \(error.localizedDescription, privacy: .private)")
                return .failed
            }
        }
        do {
            try fileManager.moveItem(at: legacy, to: current)
            return .moved
        } catch {
            logger.error("Cannot move the legacy folder: \(error.localizedDescription, privacy: .private)")
            return .failed
        }
    }

    /// Returns how many values were copied.
    @discardableResult
    func migrateDefaults(legacy: [String: Any]?, into defaults: any DefaultsAccess) -> Int {
        guard defaults.object(forKey: Self.migratedKey) == nil else { return 0 }
        var copied = 0
        for (key, value) in legacy ?? [:]
        where Self.copiedPrefixes.contains(where: key.hasPrefix) && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: Self.migratedKey)
        return copied
    }

    private func isEmptyDirectory(_ url: URL) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" }
    }
}

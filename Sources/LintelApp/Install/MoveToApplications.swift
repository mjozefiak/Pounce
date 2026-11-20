import AppKit
import Foundation
import os

/// The file operations of the Move flow. The live one is `SystemInstallFileManager`; tests and QA use fakes.
protocol InstallFileManaging {
    func itemExists(at url: URL) -> Bool
    /// Copies the bundle with `ditto` (keeps signatures, extended attributes and symbolic links inside the bundle).
    func copyBundle(from source: URL, to destination: URL) throws
    /// Moves the item to the Trash and returns where it went; never deletes it.
    func trashItem(at url: URL) throws -> URL
    /// Renames within one volume.
    func moveItem(at source: URL, to destination: URL) throws
    /// Removes a partial copy Lintel made itself (the staging copy); never used on a copy the user had.
    func removeStagingItem(at url: URL) throws
}

/// Which apps are running, by bundle location.
protocol RunningAppListing {
    func isRunning(bundleAt url: URL) -> Bool
}

/// Removes `com.apple.quarantine` from a bundle and everything inside it.
protocol QuarantineRemoving {
    func removeQuarantine(at url: URL) throws
}

/// Reads `CFBundleVersion` (the build number) of a bundle on disk; `nil` when there is no readable bundle.
protocol BundleVersionReading {
    func buildNumber(ofBundleAt url: URL) -> String?
}

/// Compares `CFBundleVersion` strings (`"123"`, `"1.2.3"`) by their dot-separated numbers.
nonisolated enum BuildNumber {
    /// `true` when `candidate` is strictly higher than `reference`. A value that is not dot-separated numbers
    /// never counts as higher, so an unreadable version never blocks a move.
    static func isHigher(_ candidate: String, than reference: String) -> Bool {
        guard let left = components(candidate), let right = components(reference) else { return false }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

/// Opens the moved copy and quits this one.
protocol AppRelaunching {
    /// `newInstance`: start a second instance of the same bundle identifier (needed when the running one is this
    /// copy); `false` activates the copy when it already runs.
    func open(_ url: URL, newInstance: Bool) async throws
    func quit()
}

/// Moves the running bundle to `/Applications` (spec `2026-11-19-updates-and-open-source-hygiene`, step 4.2).
///
/// A copy at the destination with a higher `CFBundleVersion` is never replaced: `installedCopyIsNewer` tells the
/// prompt, which then offers `openInstalledCopy` instead of `run`.
///
/// Order: refuse while a copy at the destination is running; `ditto` into a staging copy next to the destination
/// (so a failed copy changes nothing: the old copy stays where it was and this one keeps running); remove the
/// quarantine attribute from the staging copy; move an existing `Lintel.app` there to the Trash (never delete it);
/// rename the staging copy into place; open it and quit.
struct MoveToApplications {
    enum Failure: Error, Equatable {
        /// A copy at the destination is running; nothing was changed.
        case destinationRunning
        /// The installed copy has a higher build number; nothing was changed.
        case installedCopyIsNewer
        /// `ditto` failed; nothing was changed.
        case copyFailed
        /// The existing copy could not go to the Trash; nothing was changed.
        case trashFailed
        /// The new copy could not be put in place after the old one went to the Trash. `restored` says whether the
        /// old copy was put back.
        case installFailed(restored: Bool)
        /// The copy is in place but could not be opened.
        case openFailed
    }

    let files: any InstallFileManaging
    let processes: any RunningAppListing
    let quarantine: any QuarantineRemoving
    let relauncher: any AppRelaunching
    let versions: any BundleVersionReading
    var destination: URL = ApplicationLocation.destination
    /// The staging copy's name; unique per attempt.
    var stagingName: () -> String = { ".Lintel-moving-\(UUID().uuidString).app" }
    private let logger = Logger(subsystem: "com.lintelapp", category: "install")

    init(
        files: any InstallFileManaging, processes: any RunningAppListing, quarantine: any QuarantineRemoving,
        relauncher: any AppRelaunching, versions: any BundleVersionReading
    ) {
        self.versions = versions
        self.files = files
        self.processes = processes
        self.quarantine = quarantine
        self.relauncher = relauncher
    }

    /// Whether a copy at the destination has a higher build number than the bundle at `source`.
    func installedCopyIsNewer(than source: URL) -> Bool {
        guard files.itemExists(at: destination),
            let installed = versions.buildNumber(ofBundleAt: destination),
            let current = versions.buildNumber(ofBundleAt: source)
        else { return false }
        return BuildNumber.isHigher(installed, than: current)
    }

    /// Opens the installed copy and quits this one; changes nothing on disk.
    func openInstalledCopy() async throws(Failure) {
        do {
            try await relauncher.open(destination, newInstance: !processes.isRunning(bundleAt: destination))
        } catch {
            logger.error("Cannot open the installed copy: \(String(describing: error), privacy: .public)")
            throw .openFailed
        }
        relauncher.quit()
    }

    /// Moves `source` and, on success, opens the copy and quits. Throws a `Failure` otherwise. Replaces an installed
    /// copy only when `installedCopyIsNewer(than:)` is `false`; it throws `.installedCopyIsNewer` otherwise.
    func run(from source: URL) async throws(Failure) {
        guard !processes.isRunning(bundleAt: destination) else { throw .destinationRunning }
        guard !installedCopyIsNewer(than: source) else { throw .installedCopyIsNewer }
        let staging = destination.deletingLastPathComponent().appending(
            path: stagingName(), directoryHint: .isDirectory)
        do {
            try files.copyBundle(from: source, to: staging)
        } catch {
            logger.error("Copy to Applications failed: \(String(describing: error), privacy: .public)")
            removeStaging(staging)
            throw .copyFailed
        }
        do {
            try quarantine.removeQuarantine(at: staging)
        } catch {
            // Not fatal: the copy works, Gatekeeper may only check it once more.
            logger.error("Cannot remove the quarantine attribute: \(String(describing: error), privacy: .public)")
        }
        var trashed: URL?
        if files.itemExists(at: destination) {
            do {
                trashed = try files.trashItem(at: destination)
            } catch {
                logger.error("Cannot move the old copy to the Trash: \(String(describing: error), privacy: .public)")
                removeStaging(staging)
                throw .trashFailed
            }
        }
        do {
            try files.moveItem(at: staging, to: destination)
        } catch {
            logger.error("Cannot put the new copy in place: \(String(describing: error), privacy: .public)")
            removeStaging(staging)
            throw .installFailed(restored: restore(trashed))
        }
        do {
            try await relauncher.open(destination, newInstance: true)
        } catch {
            logger.error("Cannot open the moved copy: \(String(describing: error), privacy: .public)")
            throw .openFailed
        }
        relauncher.quit()
    }

    private func removeStaging(_ staging: URL) {
        guard files.itemExists(at: staging) else { return }
        do {
            try files.removeStagingItem(at: staging)
        } catch {
            logger.error("Cannot remove the staging copy: \(String(describing: error), privacy: .public)")
        }
    }

    /// Puts the trashed old copy back; `true` when there was none or it is back.
    private func restore(_ trashed: URL?) -> Bool {
        guard let trashed else { return true }
        do {
            try files.moveItem(at: trashed, to: destination)
            return true
        } catch {
            logger.error("Cannot restore the old copy: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

// MARK: - Live ports

/// `ditto` and `FileManager`.
struct SystemInstallFileManager: InstallFileManaging {
    enum DittoError: Error { case failed(Int32) }

    func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func copyBundle(from source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DittoError.failed(process.terminationStatus) }
    }

    func trashItem(at url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeStagingItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// `NSWorkspace.runningApplications`, compared by resolved bundle path.
struct SystemRunningAppListing: RunningAppListing {
    func isRunning(bundleAt url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains { application in
            guard !application.isTerminated, let bundle = application.bundleURL else { return false }
            return bundle.resolvingSymlinksInPath().standardizedFileURL.path == target
        }
    }
}

/// `CFBundleVersion` from the bundle's `Info.plist`.
struct SystemBundleVersionReader: BundleVersionReading {
    func buildNumber(ofBundleAt url: URL) -> String? {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}

/// `removexattr` on the bundle and every item inside it.
struct SystemQuarantineRemover: QuarantineRemoving {
    struct Failure: Error { let errno: Int32 }

    static let attribute = "com.apple.quarantine"

    func removeQuarantine(at url: URL) throws {
        try remove(url.path)
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            try remove(item.path)
        }
    }

    private func remove(_ path: String) throws {
        guard removexattr(path, Self.attribute, XATTR_NOFOLLOW) != 0 else { return }
        let code = errno
        // No attribute on this item is the common case.
        guard code != ENOATTR else { return }
        throw Failure(errno: code)
    }
}

/// Opens the moved copy as a new instance (the running one has the same bundle identifier) and quits.
struct SystemAppRelauncher: AppRelaunching {
    func open(_ url: URL, newInstance: Bool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = newInstance
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Quits from the run loop, not from the calling task: `terminate` waits for the shell's stop task on the main
    /// actor, which cannot run while the caller's main-actor job is still on the stack.
    func quit() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
}

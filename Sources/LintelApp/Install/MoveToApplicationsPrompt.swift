import AppKit
import LintelKit
import os

/// The launch-time offer to move Lintel to Applications (spec `2026-11-19-updates-and-open-source-hygiene`, step 4.2): decides
/// whether to ask, asks, remembers "Don't ask again" in `app.install.moveDeclined` and runs the Move flow.
struct MoveToApplicationsPrompt {
    /// Which alert is shown.
    enum Variant: Equatable {
        /// Lintel runs outside Applications: Move, Don't Move. `folder` is how the chosen folder is shown
        /// (`/Applications` or `~/Applications`).
        case move(folder: String)
        /// `/Applications` cannot be written without an administrator: offer `~/Applications` instead.
        /// `olderCopyStays`: a copy in the system Applications folder exists and cannot be replaced, so two copies
        /// will exist.
        case fallbackToUserApplications(olderCopyStays: Bool)
        /// A copy with a higher build number is already in Applications: Open Installed Copy, Don't Move. Nothing
        /// is replaced.
        case newerInstalled
    }

    /// What the user chose in the alert (`move` is the first button, whichever variant).
    struct Answer: Equatable {
        var move: Bool
        var dontAskAgain: Bool
    }

    /// What `offerIfNeeded` did.
    enum Outcome: Equatable {
        /// No alert: the app is in Applications or the user said "Don't ask again".
        case notOffered
        /// The user chose Don't Move.
        case declined
        /// The copy was opened and this instance quits.
        case moved
        /// A newer copy is installed: it was opened instead and this instance quits.
        case openedInstalledCopy
        /// The move did not happen or did not finish; the app keeps running.
        case failed(MoveToApplications.Failure)

        /// `false` once another copy was opened and this instance quits.
        var continuesLaunch: Bool { self != .moved && self != .openedInstalledCopy }
    }

    let settings: any SettingsStore
    let mover: MoveToApplications
    /// Shows the alert; the live one is `presentAlert`.
    var ask: (Variant) -> Answer = { Self.presentAlert($0, activates: true) }
    /// Shows a failure; the live one is `presentFailure`.
    var report: (MoveToApplications.Failure) -> Void = { Self.presentFailure($0, activates: true) }

    /// `app.install.moveDeclined`, default `false`.
    static func isDeclined(_ settings: any SettingsStore) -> Bool {
        if case .bool(let value) = settings.value(forKey: SettingsKeys.moveDeclined) { return value }
        return false
    }

    /// Whether to show the alert for a bundle at `bundleURL`.
    static func shouldOffer(bundleURL: URL, home: URL, settings: any SettingsStore) -> Bool {
        guard bundleURL.pathExtension == "app", !isDeclined(settings) else { return false }
        return ApplicationLocation.classify(
            bundleURL: bundleURL, allowedFolders: ApplicationLocation.allowedFolders(home: home)
        ).offersMove
    }

    /// Asks once when `shouldOffer` holds. Call it once per launch, before the plugins start, so a moved copy never
    /// runs next to a started one.
    func offerIfNeeded(bundleURL: URL, home: URL) async -> Outcome {
        guard Self.shouldOffer(bundleURL: bundleURL, home: home, settings: settings) else { return .notOffered }
        return await offer(bundleURL: bundleURL, home: home)
    }

    /// Shows the alert and acts on the answer. The folder comes from `InstallDestination.decide`.
    func offer(bundleURL: URL, home: URL) async -> Outcome {
        var mover = self.mover
        mover.home = home
        var variant: Variant
        switch InstallDestination.decide(home: home, files: mover.files) {
        case .direct(let folder):
            mover.destination = folder.appending(path: ApplicationLocation.bundleName, directoryHint: .isDirectory)
            variant = .move(folder: InstallDestination.displayPath(folder, home: home))
        case .fallbackToUserApplications(let folder), .needsAuthorization(let folder):
            _ = folder
            let stays = mover.files.itemExists(
                at: InstallDestination.systemApplications.appending(
                    path: ApplicationLocation.bundleName, directoryHint: .isDirectory))
            let user = InstallDestination.userApplications(home: home)
            mover.destination = user.appending(path: ApplicationLocation.bundleName, directoryHint: .isDirectory)
            variant = .fallbackToUserApplications(olderCopyStays: stays)
        }
        // A newer copy in either Applications folder is never replaced or shadowed by an older one in the other
        // (the chosen folder first); the alert offers to open that copy.
        let installedCopies = [
            mover.destination,
            InstallDestination.systemApplications.appending(
                path: ApplicationLocation.bundleName, directoryHint: .isDirectory),
            InstallDestination.userApplications(home: home).appending(
                path: ApplicationLocation.bundleName, directoryHint: .isDirectory),
        ]
        var probe = mover
        for copy in installedCopies {
            probe.destination = copy
            if probe.installedCopyIsNewer(than: bundleURL) {
                mover.destination = copy
                variant = .newerInstalled
                break
            }
        }
        let answer = ask(variant)
        if answer.dontAskAgain {
            settings.setValue(.bool(true), forKey: SettingsKeys.moveDeclined)
        }
        guard answer.move else { return .declined }
        do {
            if variant == .newerInstalled {
                try await mover.openInstalledCopy()
                return .openedInstalledCopy
            }
            try await mover.run(from: bundleURL)
            return .moved
        } catch {
            report(error)
            return .failed(error)
        }
    }

    // MARK: - Alerts

    static var title: String {
        String(localized: "Move Lintel to Applications?", comment: "Move to Applications alert: title")
    }

    static func message(folder: String) -> String {
        String(
            localized:
                "Lintel can update itself only from an Applications folder. It will be copied to \(folder) and opened again from there.",
            comment:
                "Move to Applications alert: explanation; the argument is the folder, /Applications or ~/Applications")
    }

    static var fallbackTitle: String {
        String(
            localized: "Move Lintel to your Applications folder?",
            comment: "Move to Applications alert: title when the system Applications folder is not writable")
    }

    static func fallbackMessage(olderCopyStays: Bool) -> String {
        let base = String(
            localized:
                "Lintel cannot write to the Applications folder without an administrator. Move it to the Applications folder in your home folder instead?",
            comment: "Move to Applications alert: explanation when the system Applications folder is not writable")
        guard olderCopyStays else { return base }
        let note = String(
            localized: "An older copy stays in Applications; an administrator can remove it.",
            comment: "Move to Applications alert: added when an existing copy in the system Applications folder stays")
        return base + " " + note
    }

    static var newerInstalledTitle: String {
        String(
            localized: "A newer Lintel is already in Applications",
            comment: "Move to Applications alert: title when the installed copy has a higher build number")
    }

    static var newerInstalledMessage: String {
        String(
            localized:
                "The copy in Applications is newer than this one, so it will not be replaced. Open it instead?",
            comment: "Move to Applications alert: explanation when the installed copy has a higher build number")
    }

    /// The alert with Move (default; Open Installed Copy for `.newerInstalled`), Don't Move and "Don't ask again".
    static func makeAlert(_ variant: Variant = .move(folder: "/Applications")) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch variant {
        case .move(let folder):
            alert.messageText = title
            alert.informativeText = message(folder: folder)
        case .fallbackToUserApplications(let olderCopyStays):
            alert.messageText = fallbackTitle
            alert.informativeText = fallbackMessage(olderCopyStays: olderCopyStays)
        case .newerInstalled:
            alert.messageText = newerInstalledTitle
            alert.informativeText = newerInstalledMessage
        }
        let move: NSButton
        switch variant {
        case .move, .fallbackToUserApplications:
            move = alert.addButton(
                withTitle: String(localized: "Move", comment: "Move to Applications alert: button that moves the app"))
            move.setAccessibilityLabel(
                String(
                    localized: "Move Lintel to the Applications folder",
                    comment: "Move to Applications alert: accessibility label of the Move button"))
        case .newerInstalled:
            move = alert.addButton(
                withTitle: String(
                    localized: "Open Installed Copy",
                    comment: "Move to Applications alert: button that opens the newer installed copy"))
            move.setAccessibilityLabel(
                String(
                    localized: "Open the newer Lintel in the Applications folder",
                    comment: "Move to Applications alert: accessibility label of the Open Installed Copy button"))
        }
        let dontMove = alert.addButton(
            withTitle: String(localized: "Don't Move", comment: "Move to Applications alert: button that keeps the app")
        )
        dontMove.setAccessibilityLabel(
            String(
                localized: "Don't move Lintel",
                comment: "Move to Applications alert: accessibility label of the Don't Move button"))
        dontMove.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        if let suppression = alert.suppressionButton {
            suppression.title = String(
                localized: "Don't ask again", comment: "Move to Applications alert: checkbox that stops the question")
            suppression.setAccessibilityLabel(
                String(
                    localized: "Don't ask again about moving Lintel",
                    comment: "Move to Applications alert: accessibility label of the Don't ask again checkbox"))
        }
        return alert
    }

    /// Runs the alert. QA mode passes `activates: false`, so the alert never takes focus from the tester.
    static func presentAlert(_ variant: Variant, activates: Bool) -> Answer {
        let alert = makeAlert(variant)
        if activates { NSApp.activate() }
        let response = alert.runModal()
        return Answer(
            move: response == .alertFirstButtonReturn, dontAskAgain: alert.suppressionButton?.state == .on)
    }

    /// The plain text of a failure.
    static func failureMessage(_ failure: MoveToApplications.Failure) -> String {
        switch failure {
        case .destinationRunning:
            String(
                localized: "Another copy of Lintel is running. Quit it and try again.",
                comment: "Move to Applications error: another copy of Lintel runs, from any location")
        case .installedCopyIsNewer:
            String(
                localized: "The copy in Applications is newer than this one, so it was not replaced.",
                comment: "Move to Applications error: the installed copy has a higher build number")
        case .copyFailed:
            String(
                localized:
                    "The copy in Applications could not be made. Nothing was changed, and Lintel keeps running from where it is.",
                comment: "Move to Applications error: the copy failed")
        case .trashFailed:
            String(
                localized: "The older copy in Applications could not be moved to the Trash. Nothing was changed.",
                comment: "Move to Applications error: the old copy could not go to the Trash")
        case .installFailedNothingReplaced:
            String(
                localized: "The new copy could not be put in Applications. Nothing was changed.",
                comment: "Move to Applications error: new copy not put in place, no older copy existed")
        case .installFailed(restored: true):
            String(
                localized: "The new copy could not be put in Applications. The older copy is back in place.",
                comment: "Move to Applications error: the new copy could not be put in place, the old one was restored")
        case .installFailed(restored: false):
            String(
                localized: "The new copy could not be put in Applications. The older copy is in the Trash.",
                comment:
                    "Move to Applications error: the new copy could not be put in place, the old one is in the Trash")
        case .openFailed:
            String(
                localized:
                    "Lintel was copied to Applications but could not be opened. Open it from the Applications folder.",
                comment: "Move to Applications error: the copy could not be opened")
        }
    }

    static func presentFailure(_ failure: MoveToApplications.Failure, activates: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Lintel couldn't be moved to Applications", comment: "Move to Applications error: title")
        alert.informativeText = failureMessage(failure)
        if activates { NSApp.activate() }
        alert.runModal()
    }
}

#if DEBUG
/// What `--qa-move-prompt` pretends the Mac looks like (`--qa-move-scenario`).
enum QAMoveScenario: String, Equatable {
    /// Nothing in `~/Applications`, `/Applications` writable: the alert names `/Applications`.
    case standard
    /// `~/Applications` holds an app: the alert names `~/Applications`.
    case userApplications = "user-applications"
    /// `/Applications` is not writable: the alert offers the home folder instead.
    case unwritable
    /// A copy with a higher build number is installed: the alert offers to open it.
    case newer
}

/// `--qa-move-prompt`: fakes for the Move flow, so the alert can be shown and answered without touching
/// `/Applications`, the Trash or the running apps. Every step is only logged.
struct QAInstallFakes: InstallFileManaging, RunningAppListing, QuarantineRemoving, AppRelaunching,
    BundleVersionReading
{
    /// The bundle location the QA alert pretends to run from.
    static let bundleURL = URL(filePath: "/Volumes/Lintel/Lintel.app", directoryHint: .isDirectory)
    var scenario = QAMoveScenario.standard
    var home = FileManager.default.homeDirectoryForCurrentUser
    private let logger = Logger(subsystem: "com.lintelapp", category: "qa")

    private var userApplications: URL { InstallDestination.userApplications(home: home) }
    private func isInstalledCopy(_ url: URL) -> Bool {
        url.path == "/Applications/Lintel.app" || url.path == userApplications.appending(path: "Lintel.app").path
    }

    func itemExists(at url: URL) -> Bool {
        (scenario == .newer && isInstalledCopy(url))
            || (scenario == .unwritable && url.path == "/Applications/Lintel.app")
    }
    func childNames(in folder: URL) -> [String] { [] }
    func directoryExists(at url: URL) -> Bool {
        url.path == "/Applications" || (scenario == .userApplications && url.path == userApplications.path)
    }
    func hasApplicationBundle(in folder: URL) -> Bool {
        scenario == .userApplications && folder.path == userApplications.path
    }
    func isWritable(at url: URL) -> Bool { !(scenario == .unwritable && url.path == "/Applications") }
    func createDirectory(at url: URL) throws {
        logger.info("QA: would create \(url.path, privacy: .public)")
    }
    func isOnReadOnlyVolume(_ url: URL) -> Bool { true }
    func isAnotherInstanceRunning(bundleIdentifier: String) -> Bool { false }
    func bundleIdentifier(ofBundleAt url: URL) -> String? { nil }
    func copyBundle(from source: URL, to destination: URL) throws {
        logger.info("QA: would copy \(source.path, privacy: .public) to \(destination.path, privacy: .public)")
    }
    func trashItem(at url: URL) throws -> URL { url }
    func moveItem(at source: URL, to destination: URL) throws {
        logger.info("QA: would rename \(source.path, privacy: .public) to \(destination.path, privacy: .public)")
    }
    func removeStagingItem(at url: URL) throws {}
    func isSameItem(_ first: URL, as second: URL) -> Bool { first.path == second.path }
    func isRunning(bundleAt url: URL) -> Bool { false }
    func removeQuarantine(at url: URL) throws {}
    func buildNumber(ofBundleAt url: URL) -> String? {
        guard scenario == .newer else { return nil }
        return isInstalledCopy(url) ? "200" : "100"
    }
    func open(_ url: URL, newInstance: Bool) async throws {
        logger.info("QA: would open \(url.path, privacy: .public) and quit")
    }
    /// QA never quits on Move; the run keeps going so the tester sees the rest of the session.
    func quit() {}
}
#endif

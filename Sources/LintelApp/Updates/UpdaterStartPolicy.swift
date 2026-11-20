import Foundation

/// Decides whether the updater may start. Pure: everything it needs is in `Facts`.
///
/// The updater starts only in a release build that runs as a bundled app from an Applications folder, is signed
/// with a Team ID (never ad-hoc) and carries the public update key. DEBUG and QA builds never start it. While
/// `SUPublicEDKey` is absent from `Info.plist` (until the owner's key exists, spec Step 4.5) no build starts it:
/// that is the switch that keeps the feature off.
nonisolated enum UpdaterStartPolicy {
    struct Facts: Equatable, Sendable {
        var isDebugBuild: Bool
        /// `Bundle.main.bundleURL`.
        var bundleURL: URL
        /// The Team ID of the running code's signature; `nil` for an ad-hoc or unsigned build.
        var teamIdentifier: String?
        /// `SUPublicEDKey` from `Info.plist`.
        var publicKey: String?
        /// `SUFeedURL` from `Info.plist`.
        var feedURL: String?
        var homeDirectory: URL
    }

    enum Refusal: String, Equatable, Sendable {
        case debugBuild
        case notAnAppBundle
        case outsideApplications
        case adHocSignature
        case noPublicKey
        case noFeed
    }

    enum Decision: Equatable, Sendable {
        case start
        case refuse(Refusal)
    }

    static func decide(_ facts: Facts) -> Decision {
        if facts.isDebugBuild { return .refuse(.debugBuild) }
        guard facts.bundleURL.pathExtension == "app" else { return .refuse(.notAnAppBundle) }
        guard isInApplications(facts.bundleURL, home: facts.homeDirectory) else {
            return .refuse(.outsideApplications)
        }
        guard let team = facts.teamIdentifier, !team.isEmpty else { return .refuse(.adHocSignature) }
        guard let key = facts.publicKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refuse(.noPublicKey)
        }
        guard let feed = facts.feedURL, feed.hasPrefix("https://") else { return .refuse(.noFeed) }
        return .start
    }

    /// Directly inside `/Applications` or `~/Applications` (not a subfolder, not App Translocation, not a disk image).
    static func isInApplications(_ bundleURL: URL, home: URL) -> Bool {
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent().path
        let allowed = ["/Applications", home.standardizedFileURL.appendingPathComponent("Applications").path]
        return allowed.contains(parent)
    }
}

import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// What an action does, comparable (the `.plugin` closure is not).
enum ActionKind: Equatable {
    case models(String?)
    case systemSettings(Permission)
    case enablePlugin
    case plugin(String)

    init(_ action: SettingsStatusAction) {
        switch action.destination {
        case .models(let packageID): self = .models(packageID)
        case .systemSettings(let permission): self = .systemSettings(permission)
        case .enablePlugin: self = .enablePlugin
        case .plugin(let id, _): self = .plugin(id)
        }
    }
}

/// Spec `2026-11-04-lintel-main-window`, step 2.2: the derivation table.
@MainActor
@Suite struct StatusDerivationTests {
    private func status(
        _ level: SettingsStatus.Level, _ title: String = "Plugin says", detail: String? = nil,
        fix: [SettingsStatusAction] = [], acknowledged: Set<Permission> = []
    ) -> SettingsStatus {
        SettingsStatus(
            level: level, title: LocalizedStringResource(stringLiteral: title),
            detail: detail.map { LocalizedStringResource(stringLiteral: $0) }, fix: fix,
            acknowledgedPermissions: acknowledged)
    }

    private func derive(
        host: StatusDerivation.HostState = .active, _ plugin: SettingsStatus?, required: [Permission] = [],
        states: [Permission: PermissionStatus] = [:]
    ) -> StatusDerivation.Banner? {
        StatusDerivation.banner(
            host: host, pluginStatus: { plugin }, required: required,
            permission: { states[$0] ?? .notDetermined })
    }

    private func kinds(_ banner: StatusDerivation.Banner?) -> [ActionKind] {
        banner?.actions.map(ActionKind.init) ?? []
    }

    // MARK: Host state first

    @Test func anOffPluginIsNeutralWithTurnOnAndItsStatusIsNotRead() {
        var reads = 0
        let banner = StatusDerivation.banner(
            host: .off,
            pluginStatus: {
                reads += 1
                return status(.error)
            }, required: [.microphone],
            permission: { _ in .denied })
        #expect(banner?.level == .neutral)
        #expect(kinds(banner) == [.enablePlugin])
        #expect(reads == 0)
    }

    @Test func aFailedPluginIsAnErrorWithTryAgainAndItsStatusIsNotRead() {
        var reads = 0
        let banner = StatusDerivation.banner(
            host: .failed,
            pluginStatus: {
                reads += 1
                return status(.ok)
            }, required: [],
            permission: { _ in .granted })
        #expect(banner?.level == .error)
        #expect(kinds(banner) == [.enablePlugin])
        #expect(reads == 0)
    }

    @Test func aPluginTurningOnOrOffShowsNothing() {
        var reads = 0
        let banner = StatusDerivation.banner(
            host: .changing,
            pluginStatus: {
                reads += 1
                return status(.error)
            }, required: [],
            permission: { _ in .granted })
        #expect(banner == nil)
        #expect(reads == 0)
    }

    // MARK: Plugin status without derived problems

    @Test func thePluginsStatusIsShownAsItIs() {
        let fix = SettingsStatusAction(title: "Get It", destination: .models(packageID: "parakeet"))
        let banner = derive(status(.attention, "Model missing", detail: "Get it.", fix: [fix]))
        #expect(banner?.level == .attention)
        #expect(banner?.title == "Model missing")
        #expect(banner?.detail == "Get it.")
        #expect(kinds(banner) == [.models("parakeet")])
    }

    @Test func atMostTwoActionsAreShown() {
        let fix = (1...3).map { SettingsStatusAction(title: "A", destination: .plugin(id: "a\($0)") {}) }
        #expect(kinds(derive(status(.attention, fix: fix))) == [.plugin("a1"), .plugin("a2")])
    }

    @Test func nothingToSayGivesNoBanner() {
        #expect(derive(nil) == nil)
        #expect(derive(nil, required: [.microphone], states: [.microphone: .granted]) == nil)
    }

    // MARK: Derivation and the level order

    @Test func aDeniedReadablePermissionWithoutAPluginStatusIsAttention() {
        let banner = derive(nil, required: [.microphone], states: [.microphone: .denied])
        #expect(banner?.level == .attention)
        #expect(kinds(banner) == [.systemSettings(.microphone)])
    }

    @Test func pluginOkPlusDeniedIsAttentionWithSystemSettings() {
        let banner = derive(status(.ok, "Ready"), required: [.microphone], states: [.microphone: .denied])
        #expect(banner?.level == .attention)
        #expect(banner?.title != "Ready")
        #expect(kinds(banner).first == .systemSettings(.microphone))
    }

    @Test func pluginNeutralCountsAsOkSoDeniedWins() {
        let banner = derive(status(.neutral), required: [.accessibility], states: [.accessibility: .denied])
        #expect(banner?.level == .attention)
        #expect(kinds(banner) == [.systemSettings(.accessibility)])
    }

    @Test func pluginOkPlusAcknowledgedDeniedIsOk() {
        let banner = derive(
            status(.ok, "Indexing", acknowledged: [.fullDiskAccess]), required: [.fullDiskAccess],
            states: [.fullDiskAccess: .denied])
        #expect(banner?.level == .ok)
        #expect(banner?.title == "Indexing")
        #expect(kinds(banner).isEmpty)
    }

    @Test func pluginOkPlusUnreadableSystemAudioIsOk() {
        let banner = derive(
            status(.ok, "Ready"), required: [.microphone, .systemAudioRecording],
            states: [.microphone: .granted])
        #expect(banner?.level == .ok)
        #expect(banner?.title == "Ready")
    }

    @Test func anUnreadablePermissionIsNeutralOnlyWithoutAPluginStatus() {
        let banner = derive(nil, required: [.systemAudioRecording])
        #expect(banner?.level == .neutral)
        #expect(kinds(banner).isEmpty)
        // A denied readable permission is worse than the unreadable one.
        let denied = derive(
            nil, required: [.microphone, .systemAudioRecording], states: [.microphone: .denied])
        #expect(denied?.level == .attention)
    }

    @Test func pluginErrorPlusDeniedStaysAnErrorAndKeepsItsTitle() {
        let retry = SettingsStatusAction(title: "Try Again", destination: .plugin(id: "retry") {})
        let banner = derive(
            status(.error, "History is paused", detail: "Key locked.", fix: [retry]), required: [.pasteboard],
            states: [.pasteboard: .denied])
        #expect(banner?.level == .error)
        #expect(banner?.title == "History is paused")
        #expect(banner?.detail?.hasPrefix("Key locked.") == true)
        #expect(banner?.detail?.contains(Permission.pasteboard.title) == true)
        #expect(kinds(banner) == [.plugin("retry"), .systemSettings(.pasteboard)])
    }

    @Test func pluginAttentionPlusDeniedKeepsItsTitleAndThePermissionGoesIntoTheDetail() {
        let banner = derive(
            status(.attention, "1 thing to do"), required: [.microphone],
            states: [.microphone: .denied])
        #expect(banner?.level == .attention)
        #expect(banner?.title == "1 thing to do")
        #expect(banner?.detail?.contains(Permission.microphone.title) == true)
        #expect(kinds(banner) == [.systemSettings(.microphone)])
    }

    @Test func aSystemSettingsFixThePluginOffersIsNotRepeated() {
        let open = SettingsStatusAction(title: "Allow", destination: .systemSettings(.microphone))
        let banner = derive(status(.attention, fix: [open]), required: [.microphone], states: [.microphone: .denied])
        #expect(kinds(banner) == [.systemSettings(.microphone)])
    }

    @Test func notDeterminedGivesNoBannerFromDerivation() {
        #expect(derive(nil, required: [.microphone], states: [.microphone: .notDetermined]) == nil)
        let banner = derive(status(.ok, "Ready"), required: [.microphone], states: [.microphone: .notDetermined])
        #expect(banner?.level == .ok)
        // A plugin may still report it itself, with its own action.
        let ask = SettingsStatusAction(title: "Allow Microphone", destination: .plugin(id: "allowMicrophone") {})
        let reported = derive(status(.attention, fix: [ask]), required: [.microphone])
        #expect(reported?.level == .attention)
        #expect(kinds(reported) == [.plugin("allowMicrophone")])
    }

    @Test func theLevelOrderIsErrorAttentionOk() {
        #expect(StatusDerivation.rank(.error) > StatusDerivation.rank(.attention))
        #expect(StatusDerivation.rank(.attention) > StatusDerivation.rank(.ok))
        #expect(StatusDerivation.rank(.neutral) == StatusDerivation.rank(.ok))
    }

    // MARK: Accessibility

    @Test func theAccessibilityLabelIsOneStringWithLevelTitleAndDetail() {
        let banner = derive(status(.error, "History is paused", detail: "Nothing was deleted."))
        let label = banner?.accessibilityLabel
        #expect(label == "\(StatusDerivation.levelName(.error)), History is paused, Nothing was deleted.")
        #expect(derive(status(.ok, "Ready"))?.accessibilityLabel == "\(StatusDerivation.levelName(.ok)), Ready")
    }
}

import LintelKit
import Testing

@testable import LintelApp
@testable import WindowsPlugin

/// Round 10 F1: the safe-mode banner must not take Try Again away from the other start errors. Only safe mode brings
/// its own banner (`SafeModeFailure`); every `StartError` keeps the host's generic banner, with its button.
@Suite struct WindowsStartFailureBannerTests {
    private func banner(for error: any Error) -> StatusDerivation.Banner? {
        StatusDerivation.banner(
            host: .failed, pluginStatus: { nil }, required: [], permission: { _ in .granted },
            failureStatus: (error as? any PluginFailureStatus)?.failureStatus)
    }

    private func destinations(_ banner: StatusDerivation.Banner?) -> [String] {
        (banner?.actions ?? []).map {
            if case .enablePlugin = $0.destination { "enablePlugin" } else { "other" }
        }
    }

    private let generic = StatusDerivation.banner(
        host: .failed, pluginStatus: { nil }, required: [], permission: { _ in .granted })

    @Test func everyStartErrorKeepsTheGenericBannerWithTryAgain() {
        let errors: [WindowsPlugin.StartError] = [
            .unsupported(reason: "x"), .stillStopping, .failed(reason: "Boom"),
        ]
        for error in errors {
            let shown = banner(for: error)
            #expect(shown?.title == generic?.title, "\(error)")
            #expect(shown?.detail == generic?.detail, "\(error)")
            #expect(shown?.level == generic?.level, "\(error)")
            #expect(destinations(shown) == ["enablePlugin"], "\(error) must offer Try Again")
            #expect(!(error is any PluginFailureStatus))
        }
    }

    @Test func safeModeHasItsOwnBannerWithTryAgain() {
        let shown = banner(for: WindowsPlugin.SafeModeFailure())
        #expect(shown?.level == .attention)
        #expect(shown?.title == "Switched off after a problem")
        #expect(shown?.title != generic?.title)
        #expect(destinations(shown) == ["enablePlugin"])
    }
}

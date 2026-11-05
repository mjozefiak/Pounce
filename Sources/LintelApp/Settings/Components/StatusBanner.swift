import LintelKit
import LintelUI
import SwiftUI

/// The one status banner above a Settings pane in the main window (spec step 2.2), drawn by `SettingsHost`.
/// The glyph takes its colour from the `status.*` tokens; the text stays in the label colours. The icon, title
/// and detail are announced as one unit; the buttons (at most two, the first is primary) follow it.
struct StatusBanner: View {
    let banner: StatusDerivation.Banner
    /// True while an action runs: the buttons are disabled.
    let isBusy: Bool
    let onAction: (SettingsStatusAction) -> Void

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbolName(banner.level))
                    .font(textSize.font(.title3))
                    .foregroundStyle(Self.color(banner.level))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: banner.title)
                        .font(textSize.font(.body, weight: .semibold))
                    if let detail = banner.detail {
                        Text(verbatim: detail)
                            .font(textSize.font(.callout))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: banner.accessibilityLabel))
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("settings.banner.text")

            let actions = Array(banner.actions.prefix(StatusDerivation.maximumActions))
            ForEach(actions.indices, id: \.self) { index in
                button(actions[index], primary: index == 0)
            }
        }
        .padding(12)
        .background(
            Self.color(banner.level).opacity(LintelBrand.statusTintAlpha), in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.banner")
    }

    @ViewBuilder
    private func button(_ action: SettingsStatusAction, primary: Bool) -> some View {
        let label = Text(action.title).font(textSize.font(.callout))
        if primary {
            Button {
                onAction(action)
            } label: {
                label
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
        } else {
            Button {
                onAction(action)
            } label: {
                label
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
    }

    static func symbolName(_ level: SettingsStatus.Level) -> String {
        switch level {
        case .ok: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .neutral: "info.circle.fill"
        }
    }

    static func color(_ level: SettingsStatus.Level) -> Color {
        switch level {
        case .ok: LintelBrand.statusOk
        case .attention: LintelBrand.statusAttention
        case .error: LintelBrand.statusError
        // No brand token for neutral: the system's secondary label colour.
        case .neutral: Color(nsColor: .secondaryLabelColor)
        }
    }
}

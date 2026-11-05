import SwiftUI

/// The template of a plugin settings pane (spec `2026-11-04-lintel-main-window`, UI/UX): Basics on top, an
/// Advanced `DisclosureGroup` and a Data section. It has no banner slot: the host draws the one `StatusBanner`
/// above the pane. Text sizes come from `lintelTextSize`, colours from `LintelBrand`, and the form uses system
/// fills (no glass).
public struct SettingsPane<Basics: View, Advanced: View, Data: View>: View {
    private let basics: Basics
    private let advanced: Advanced?
    private let data: Data?
    /// The Data section's header; `nil` is "Data". Dictation calls it "History" (prototype `set-dictation`).
    private let dataTitle: LocalizedStringResource?

    @Environment(\.lintelTextSize) private var textSize
    @State private var advancedExpanded = false

    public init(
        dataTitle: LocalizedStringResource? = nil,
        @ViewBuilder basics: () -> Basics,
        @ViewBuilder advanced: () -> Advanced,
        @ViewBuilder data: () -> Data
    ) {
        self.basics = basics()
        self.advanced = advanced()
        self.data = data()
        self.dataTitle = dataTitle
    }

    fileprivate init(basics: Basics, advanced: Advanced?, data: Data?, dataTitle: LocalizedStringResource? = nil) {
        self.basics = basics
        self.advanced = advanced
        self.data = data
        self.dataTitle = dataTitle
    }

    public var body: some View {
        Form {
            basics
            if let advanced {
                Section {
                    DisclosureGroup(isExpanded: $advancedExpanded) {
                        advanced
                    } label: {
                        Text("Advanced", comment: "Settings pane section title")
                            .font(textSize.font(.body, weight: .semibold))
                    }
                }
            }
            if let data {
                Section {
                    data
                } header: {
                    Group {
                        if let dataTitle {
                            Text(dataTitle)
                        } else {
                            Text("Data", comment: "Settings pane section title for the data a feature keeps")
                        }
                    }
                    .font(textSize.font(.body, weight: .semibold))
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension SettingsPane where Advanced == EmptyView, Data == EmptyView {
    public init(@ViewBuilder basics: () -> Basics) {
        self.init(basics: basics(), advanced: nil, data: nil)
    }
}

extension SettingsPane where Data == EmptyView {
    public init(@ViewBuilder basics: () -> Basics, @ViewBuilder advanced: () -> Advanced) {
        self.init(basics: basics(), advanced: advanced(), data: nil)
    }
}

extension SettingsPane where Advanced == EmptyView {
    public init(
        dataTitle: LocalizedStringResource? = nil, @ViewBuilder basics: () -> Basics, @ViewBuilder data: () -> Data
    ) {
        self.init(basics: basics(), advanced: nil, data: data(), dataTitle: dataTitle)
    }
}

/// The one-sentence footer under a setting: secondary colour, scaled text. Anything longer belongs in `.help` or
/// a Learn more link; the source-scanning test `no-long-footer` rejects literals over `maxLength` characters.
public struct SettingsFooter: View {
    /// Longest footer literal the scanning test accepts.
    public static let maxLength = 140

    private let text: LocalizedStringResource
    @Environment(\.lintelTextSize) private var textSize

    public init(_ text: LocalizedStringResource) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(textSize.font(.callout))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

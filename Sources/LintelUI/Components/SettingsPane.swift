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
                SettingsDisclosureSection(isExpanded: $advancedExpanded) {
                    advanced
                } label: {
                    Text("Advanced", comment: "Settings pane section title")
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
                    .settingsSectionHeader()
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

/// The look of a section header in a settings form. In the main window (prototype `.sh`): the subheadline style,
/// semibold, secondary colour. The old window keeps its body-size semibold headers.
public struct SettingsSectionHeaderStyle: ViewModifier {
    @Environment(\.settingsHostStyle) private var hostStyle
    @Environment(\.lintelTextSize) private var textSize

    public init() {}

    public func body(content: Content) -> some View {
        if hostStyle == .mainWindow {
            content
                .font(textSize.font(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
        } else {
            content.font(textSize.font(.body, weight: .semibold))
        }
    }
}

extension View {
    /// Styles a settings section header (`SettingsSectionHeaderStyle`).
    public func settingsSectionHeader() -> some View { modifier(SettingsSectionHeaderStyle()) }
}

/// A collapsible settings section: Advanced in `SettingsPane`, Storage in Models. In the main window it is a plain
/// line (prototype `.disc`: a chevron and a secondary semibold label, no card) and the rows appear in a card under
/// it when expanded; the old window keeps a `DisclosureGroup` in its own card.
public struct SettingsDisclosureSection<Content: View, Label: View, Footer: View>: View {
    @Binding private var isExpanded: Bool
    private let content: Content
    private let label: Label
    private let footer: Footer

    @Environment(\.settingsHostStyle) private var hostStyle
    @Environment(\.lintelTextSize) private var textSize

    public init(
        isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label,
        @ViewBuilder footer: () -> Footer
    ) {
        _isExpanded = isExpanded
        self.content = content()
        self.label = label()
        self.footer = footer()
    }

    /// The space under the collapsed line (prototype `.sh`, margin-top 18, less the form's own section gap).
    static var collapsedGap: CGFloat { 10 }

    public var body: some View {
        if hostStyle == .mainWindow {
            Section {
                if isExpanded { content }
            } header: {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(textSize.font(.caption1, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                        label.font(textSize.font(.callout, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    // Collapsed, the line stands alone: keep the prototype's gap to the next section's header.
                    .padding(.bottom, isExpanded ? 0 : Self.collapsedGap)
                }
                .buttonStyle(.plain)
                .accessibilityValue(
                    isExpanded
                        ? Text("Expanded", comment: "Disclosure state, spoken")
                        : Text("Collapsed", comment: "Disclosure state, spoken")
                )
                .accessibilityIdentifier("settings.disclosure")
            } footer: {
                footer
            }
        } else {
            Section {
                DisclosureGroup(isExpanded: $isExpanded) {
                    content
                } label: {
                    label.font(textSize.font(.body, weight: .semibold))
                }
            } footer: {
                footer
            }
        }
    }
}

extension SettingsDisclosureSection where Footer == EmptyView {
    public init(
        isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label
    ) {
        self.init(isExpanded: isExpanded, content: content, label: label, footer: { EmptyView() })
    }
}

import AppKit
import SwiftUI

/// Settings → General → Text Size. macOS has no Dynamic Type, so this scales the panel's text styles. Hosts pass
/// it down with `.lintelTextSize(_:)`; views read it from the environment value `lintelTextSize`.
public nonisolated enum TextSize: String, CaseIterable, Identifiable, Sendable {
    case small = "s"
    case medium = "m"
    case large = "l"
    case extraLarge = "xl"

    public var id: String { rawValue }

    public static let `default` = TextSize.medium

    public init(setting: String?) {
        self = setting.flatMap(TextSize.init(rawValue:)) ?? .default
    }

    public var title: LocalizedStringResource {
        switch self {
        case .small: LocalizedStringResource("S", comment: "Text size option: small")
        case .medium: LocalizedStringResource("M", comment: "Text size option: medium")
        case .large: LocalizedStringResource("L", comment: "Text size option: large")
        case .extraLarge: LocalizedStringResource("XL", comment: "Text size option: extra large")
        }
    }

    public var accessibilityName: LocalizedStringResource {
        switch self {
        case .small: LocalizedStringResource("Small", comment: "Text size option, spoken")
        case .medium: LocalizedStringResource("Medium", comment: "Text size option, spoken")
        case .large: LocalizedStringResource("Large", comment: "Text size option, spoken")
        case .extraLarge: LocalizedStringResource("Extra Large", comment: "Text size option, spoken")
        }
    }

    /// Factor applied to every text style and to the row metrics.
    public var scale: CGFloat {
        switch self {
        case .small: 0.9
        case .medium: 1
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }

    public var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: .medium
        case .medium: .large
        case .large: .xLarge
        case .extraLarge: .xxLarge
        }
    }

    /// A system text style scaled for this size: still the system font and the style's weight, never a
    /// fixed point size.
    @MainActor public func font(_ style: NSFont.TextStyle, weight: NSFont.Weight? = nil) -> Font {
        let base = NSFont.preferredFont(forTextStyle: style)
        var font = base.withSize(base.pointSize * scale)
        if let weight {
            font = NSFont.systemFont(ofSize: font.pointSize, weight: weight)
        }
        return Font(font)
    }

    @MainActor public func nsFont(_ style: NSFont.TextStyle) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return base.withSize(base.pointSize * scale)
    }
}

import SwiftUI

extension EnvironmentValues {
    /// The app's text size (`app.textSize`), set by every host through `.lintelTextSize(_:)`.
    @Entry public var lintelTextSize: TextSize = .default
}

extension View {
    /// Sets the text size for everything below: the `lintelTextSize` environment value, which views read their
    /// sizes through, and the matching `dynamicTypeSize`, so the system text styles follow too.
    public func lintelTextSize(_ size: TextSize) -> some View {
        environment(\.lintelTextSize, size).dynamicTypeSize(size.dynamicTypeSize)
    }
}

/// The app's text size (`app.textSize`) for windows a plugin opens itself (the meeting window), which no shell
/// host wraps. `LintelApp` sets it once at start to a closure over its observed setting; a plugin window reads it
/// through `LintelTextSizeScope`, so a change applies at once.
@MainActor public enum AppTextSize {
    public static var current: () -> TextSize = { .default }
}

/// A host's root view that reads the text size while SwiftUI renders it, so a size read from an `@Observable`
/// setting (`AppSettings.textSize`) is tracked and the content follows a change at once.
public struct LintelTextSizeScope<Content: View>: View {
    private let size: () -> TextSize
    private let content: Content

    public init(size: @escaping () -> TextSize, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }

    public var body: some View {
        content.lintelTextSize(size())
    }
}

import SwiftUI

/// A menu picker in a settings row whose chosen value follows the text size (a labelled `Picker` in a grouped
/// form draws its value at the system size; a hidden-label one inside `LabeledContent` takes the font). Shared by
/// the Dictation and Meetings panes.
public struct MenuPicker<Value: Hashable, Options: View, Label: View>: View {
    let selection: Binding<Value>
    let options: Options
    let label: Label
    /// The picker's own (hidden, spoken) name when the row label holds more than a title, such as a link.
    let title: Text?
    @Environment(\.lintelTextSize) private var textSize

    public init(
        selection: Binding<Value>, title: Text? = nil, @ViewBuilder content: () -> Options,
        @ViewBuilder label: () -> Label
    ) {
        self.selection = selection
        self.title = title
        self.options = content()
        self.label = label()
    }

    public var body: some View {
        LabeledContent {
            Picker(selection: selection) {
                options
            } label: {
                if let title { title } else { label }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(textSize.font(.body))
            .fixedSize()
        } label: {
            label
        }
    }
}

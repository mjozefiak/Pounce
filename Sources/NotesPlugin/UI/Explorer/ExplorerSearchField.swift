import LintelKit
import LintelUI
import SwiftUI

/// The explorer's search field (prototype `.exs`).
struct ExplorerSearchField: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .accessibilityHidden(true)
            TextField(
                text: $model.searchText,
                prompt: Text("Search notes", comment: "Explorer: placeholder of the search field")
            ) {
                Text("Search notes", comment: "Accessibility label of the explorer's search field")
            }
            .textFieldStyle(.plain)
            .focused($focused)
            .foregroundStyle(LintelBrand.ink)
            .onExitCommand { Task { await model.clearSearch() } }
            if !model.searchText.isEmpty {
                Button {
                    Task { await model.clearSearch() }
                } label: {
                    Image(systemName: "xmark")
                        .font(textSize.font(.caption1, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text("Clear search", comment: "Accessibility label of the search field's clear button"))
            }
        }
        .font(textSize.font(.callout))
        .foregroundStyle(LintelBrand.secondaryText)
        .padding(.horizontal, 10 * textSize.scale)
        .padding(.vertical, 6 * textSize.scale)
        .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10 * textSize.scale)
        .padding(.vertical, 6 * textSize.scale)
        // A short pause, so typing does not list on every key.
        .task(id: model.searchText) {
            if model.searchText.isEmpty {
                await model.runSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled { await model.runSearch() }
        }
    }
}

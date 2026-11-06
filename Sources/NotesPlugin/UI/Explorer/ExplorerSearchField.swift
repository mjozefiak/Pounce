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

/// What the explorer says when a search found nothing (prototype `.nr`): what was asked and where a search looks.
struct ExplorerNoResults: View {
    let query: String
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            Text("No notes match “\(query)”.", comment: "Explorer: a search found nothing; the query")
            Text(
                "Search covers titles, notes, transcripts and dictations.", comment: "Explorer: what a search looks in")
        }
        .font(textSize.font(.callout))
        .foregroundStyle(LintelBrand.secondaryText)
        .multilineTextAlignment(.center)
        .padding(18 * textSize.scale)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

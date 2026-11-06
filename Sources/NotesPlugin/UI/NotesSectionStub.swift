import LintelKit
import LintelUI
import SwiftUI

/// The placeholder content of the Notes section until Phase 3 builds the explorer and the document. Note titles
/// are other people's words: shown verbatim, never rendered as Markdown.
struct NotesSectionStub: View {
    let notes: [NoteSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if notes.isEmpty {
                Text("No notes yet", comment: "Notes section: nothing to show")
                    .foregroundStyle(LintelBrand.secondaryText)
            } else {
                ForEach(notes) { note in
                    Text(verbatim: note.title ?? note.id.rawValue)
                        .foregroundStyle(LintelBrand.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(LintelBrand.windowBackground)
    }
}

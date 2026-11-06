import LintelKit
import LintelUI
import SwiftUI

/// The strip that asks before the user's own kept text (a `human` proposal) is removed for good. Keep is the
/// plain default; removing is a separate, explicit press.
struct ProposalDiscardConfirm: View {
    let model: NotesWorkspaceModel
    let revisionID: Int64
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * textSize.scale) {
            Text("Remove your text for good?", comment: "Compare and History: asks before the user's own kept text is removed")
                .font(textSize.font(.footnote, weight: .semibold))
                .foregroundStyle(LintelBrand.ink)
            HStack(spacing: 8 * textSize.scale) {
                Button {
                    model.cancelDiscard()
                } label: {
                    Text("Keep my text", comment: "Compare and History: cancels removing the user's own kept text")
                        .font(textSize.font(.footnote, weight: .semibold))
                        .foregroundStyle(LintelBrand.ink)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                Button {
                    Task { await model.confirmDiscard(revisionID: revisionID) }
                } label: {
                    Text("Remove my text", comment: "Compare and History: confirms removing the user's own kept text")
                        .font(textSize.font(.footnote, weight: .semibold))
                        .foregroundStyle(LintelBrand.statusError)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8 * textSize.scale)
        .background(LintelBrand.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LintelBrand.hairline))
        .accessibilityElement(children: .contain)
    }
}

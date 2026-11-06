import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct OverlaySeederTests {
    private func layer(_ text: String = "text") -> NoteLayer {
        NoteLayer(id: "notes", author: .agent, markdown: text, version: "v1")
    }

    @Test func seedingIsAllowedInTheSpecifiedStatesOnly() {
        let allowed: [NoteState] = [.ready, .partial, .stale, .failed, .needsModel, .interrupted]
        let refused: [NoteState] = [.recording, .processing, .writing(done: 1, of: 3)]
        for state in allowed { #expect(OverlaySeeder.canSeed(state: state, layer: layer()), "\(state)") }
        for state in refused { #expect(!OverlaySeeder.canSeed(state: state, layer: layer()), "\(state)") }
    }

    @Test func aLayerWithoutTextIsNeverSeeded() {
        for state in [NoteState.ready, .interrupted, .failed] {
            #expect(!OverlaySeeder.canSeed(state: state, layer: layer("  \n ")), "\(state)")
        }
    }

    @Test func thePlanFreezesTheRenderedLayerAndTheRoundedStart() throws {
        let rig = try DocRig()
        let started = Date(timeIntervalSince1970: 1_800_000_000.0004)
        let plan = try rig.plan(rig.layer("rendered", version: "v9"), startedAt: started)
        #expect(plan.snapshot.version == "v9")
        #expect(plan.startedAtMs == 1_800_000_000_000)
        #expect(
            OverlaySeeder.plan(content: rig.content(layers: [rig.layer("x")], state: .recording), layerID: "notes")
                == nil)
        #expect(OverlaySeeder.plan(content: rig.content(layers: [rig.layer("x")]), layerID: "other") == nil)
    }

    @Test func aSeedWithoutEditingIsOneRevisionOfTheLayersOwnAuthorAndSeedsOncePerLayer() throws {
        let rig = try DocRig()
        let plan = try rig.plan(rig.layer("agent notes", version: "v3"))
        let first = try OverlaySeeder.seed(plan, in: rig.store, now: Date())
        let again = try OverlaySeeder.seed(plan, in: rig.store, now: Date())
        #expect(first.id == again.id)
        let revisions = try rig.store.revisions(of: first.id)
        #expect(revisions.count == 1)
        #expect(revisions.first?.author == "agent")
        #expect(first.sourceVersionSeen == "v3")
        // Only the layer being edited is copied: the transcript has no row.
        #expect(try rig.store.liveDocuments(key: rig.meeting).map(\.layer) == ["notes"])
        #expect(!(try rig.store.hasUserWriting(first.id)))
    }
}

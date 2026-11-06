import Foundation
import LintelSpeech
import Testing

@testable import MeetingsPlugin
@testable import NotesPlugin

/// Spec `2026-11-04-notes-workspace`, step 6.2: with the same catalog model in both settings, a Notes revise run and
/// Meetings' notes pipeline take the same `LLMLease` key, so they share one resident model (and, with different
/// models, the second waits on `busy`).
@MainActor
@Suite struct NotesReviseKeyTests {
    @Test func theNotesKeyEqualsMeetingsNotesPipelineKeyForTheSameModelFile() {
        for model in LLMModelCatalog.all {
            let file = URL(filePath: "/models/llm/\(model.id)/\(model.id).gguf")
            let meetings = NotesModel(
                lease: LLMLease(), runtime: LlamaRuntime(contextLength: NotesModel.contextLength), modelURL: file)
            #expect(ReviseModelKey.make(modelFile: file) == meetings.key)
            #expect(LeasedReviseModel(modelURL: file).key == meetings.key)
        }
        #expect(ReviseModelKey.contextLength == NotesModel.contextLength)
    }

    @Test func anotherModelFileIsAnotherKey() {
        let a = URL(filePath: "/models/llm/a/a.gguf")
        let b = URL(filePath: "/models/llm/b/b.gguf")
        #expect(ReviseModelKey.make(modelFile: a) != ReviseModelKey.make(modelFile: b))
    }
}

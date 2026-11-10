import Foundation
import Testing

@testable import NotesPlugin

/// The corpus through the real planner, prompt and guard with a model that goes wrong in a known way. Deterministic
/// and offline; what a real model does with the same notes is `RealReviseTests` (off by default).
///
/// The snapshots (`Fixtures/revise/snapshots/`) are what the model is sent (`<name>.prompt.txt`) and what the note
/// becomes (`<name>.expected.md`) for each case, under the prompt version in `PROMPT_VERSION`: change the prompt
/// and the test fails until the snapshots are written again with `LINTEL_REVISE_WRITE_SNAPSHOTS=1` (and read in the
/// diff). Nothing here loads a model.
@Suite struct ReviseRegressionTests {
    private static let snapshotDirectory = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/revise/snapshots")

    private static var writing: Bool { ProcessInfo.processInfo.environment["LINTEL_REVISE_WRITE_SNAPSHOTS"] != nil }

    @Test func theCorpusIsComplete() throws {
        let cases = try ReviseCorpusCase.all()
        #expect(
            Set(cases.map(\.name)) == [
                "pl-sprint", "en-one-unit", "extra-unit-injection", "markup-bait", "delimiters-in-text",
                "model-keeps-block", "mixed-structure", "edited-after-comment", "colon-words-and-link-period",
            ])
        #expect(Set(cases.map(\.language)) == ["pl", "en"])
        for corpus in cases {
            #expect(!corpus.comments.isEmpty && !corpus.modelAnswer.isEmpty, "\(corpus.name) says nothing")
            #expect(!corpus.description.isEmpty)
        }
    }

    @Test func everyCaseEndsAsItsExpectationSays() throws {
        for corpus in try ReviseCorpusCase.all() {
            let plan = try corpus.plan()
            let expect = corpus.expect
            let verdict: ReviseGuard.Verdict
            do {
                verdict = try ReviseGuard.check(head: corpus.note, plan: plan, answer: corpus.modelAnswer)
            } catch let rejection as ReviseGuard.RunRejection {
                #expect(
                    String(describing: rejection) == expect.runRejection,
                    "\(corpus.name): refused with \(rejection)")
                continue
            }
            #expect(expect.runRejection == nil, "\(corpus.name): the whole answer should have been refused")
            #expect(verdict.applied.map(\.unitID) == expect.applied, "\(corpus.name): applied")
            #expect(
                Dictionary(
                    uniqueKeysWithValues: verdict.rejected.map { (String($0.unitID), String(describing: $0.reason)) })
                    == expect.rejected,
                "\(corpus.name): rejected")
            #expect(verdict.unchanged.map(\.unitID) == expect.unchanged, "\(corpus.name): unchanged")
            #expect(
                verdict.skipped.flatMap { skip in skip.threadIDs.map { _ in String(describing: skip.reason) } }
                    == expect.skipped,
                "\(corpus.name): skipped")
            for text in expect.keep { #expect(verdict.body.contains(text), "\(corpus.name): \(text) is missing") }
            for text in expect.drop { #expect(!verdict.body.contains(text), "\(corpus.name): \(text) got in") }
            // An answer that changed no block is no edit: the note is byte for byte the one it was.
            if verdict.applied.isEmpty { #expect(verdict.body == corpus.note, "\(corpus.name): body changed") }
            ReviseInvariants.check(note: corpus.note, plan: plan, verdict: verdict, context: corpus.name)
        }
    }

    @Test func theAnswerOfARefusedRunIsNeverUsedAndTheNoteStaysAsItWas() throws {
        let corpus = try #require(try ReviseCorpusCase.all().first { $0.name == "extra-unit-injection" })
        #expect(throws: ReviseGuard.RunRejection.outsideBlockChanged) {
            try ReviseGuard.check(head: corpus.note, plan: try corpus.plan(), answer: corpus.modelAnswer)
        }
    }

    @Test func theMarkersInTheNoteAreEscapedInThePromptAndNeverForgeAUnit() throws {
        for corpus in try ReviseCorpusCase.all() {
            let plan = try corpus.plan()
            guard !plan.units.isEmpty else { continue }
            let user = try #require(ReviseNotesPrompt.messages(units: plan.units).last?.content)
            let count = plan.units.count
            for tag in ["</blocks>", "</comments>", "</unit>"] {
                #expect(user.components(separatedBy: tag).count - 1 == count, "\(corpus.name): \(tag) is forged")
            }
            #expect(
                user.components(separatedBy: "<unit id=").count - 1 == count, "\(corpus.name): a unit tag is forged")
            #expect(!user.contains("[[unit"), "\(corpus.name): a marker stands in the data")
        }
    }

    // MARK: Snapshots

    @Test func thePromptAndTheResultMatchTheSnapshots() throws {
        let version = Self.snapshotDirectory.appending(path: "PROMPT_VERSION")
        if Self.writing { try write("\(ReviseNotesPrompt.version)\n", to: version) }
        #expect(
            try String(contentsOf: version, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                == "\(ReviseNotesPrompt.version)",
            "the prompt version changed: write the snapshots again (LINTEL_REVISE_WRITE_SNAPSHOTS=1) and read the diff")
        for corpus in try ReviseCorpusCase.all() {
            let plan = try corpus.plan()
            if !plan.units.isEmpty {
                let prompt = try #require(ReviseNotesPrompt.messages(units: plan.units).last?.content)
                try match(prompt + "\n", file: "\(corpus.name).prompt.txt")
            }
            if let verdict = try? ReviseGuard.check(head: corpus.note, plan: plan, answer: corpus.modelAnswer) {
                try match(verdict.body + "\n", file: "\(corpus.name).expected.md")
            }
        }
    }

    private func match(_ text: String, file: String) throws {
        let url = Self.snapshotDirectory.appending(path: file)
        if Self.writing { try write(text, to: url) }
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(stored == text, "\(file) differs from what the code produces")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

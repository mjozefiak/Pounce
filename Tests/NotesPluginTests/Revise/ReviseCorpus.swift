import Foundation
import LintelCore
import Testing

@testable import NotesPlugin

/// The regression corpus of the revise run (`Fixtures/revise/`): short notes in Polish and English with comments, and
/// the answer of a model that goes wrong in one way per case (`modelAnswer`, in the model's own `[[unit N]]` format),
/// plus what the guard must make of it. The offline tests feed `modelAnswer` through the real planner, prompt and
/// guard; `RealReviseTests` (off by default) runs a real model on the same notes and comments.
struct ReviseCorpusCase: Decodable, Sendable {
    struct Comment: Decodable, Sendable {
        var quote: String
        /// The comment and its replies, in order.
        var bodies: [String]
    }

    struct Expectation: Decodable, Sendable {
        /// `RunRejection` case name when the whole answer must be refused.
        var runRejection: String?
        /// Unit ids the guard applies.
        var applied: [Int]
        /// Unit id (as text) to the `BlockRejection` case name.
        var rejected: [String: String]
        /// Unit ids whose answer equals the input.
        var unchanged: [Int]
        /// `ReviseSkip.Reason` case names, one per skipped thread.
        var skipped: [String]
        /// Text that stands in the finished note.
        var keep: [String]
        /// Text that must not.
        var drop: [String]
    }

    var name: String
    var language: String
    var description: String
    /// The note as it was when the comments were made, when it differs from `note` (a human edited a block since).
    var noteWhenCommented: String?
    var note: String
    var comments: [Comment]
    var modelAnswer: String
    var expect: Expectation

    func threads() throws -> [CommentThread] {
        let at = noteWhenCommented ?? note
        return try comments.enumerated().map { offset, comment in
            try ReviseFixtures.thread(Int64(offset + 1), quote: comment.quote, in: at, comments: comment.bodies)
        }
    }

    func plan() throws -> RevisePlan { ReviseFixtures.plan(note, try threads()) }

    // MARK: Loading

    static func directory() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/revise", withExtension: nil))
    }

    static func all() throws -> [ReviseCorpusCase] {
        let directory = try directory()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasSuffix(".json")
        }.sorted()
        return try names.map {
            try JSONDecoder().decode(ReviseCorpusCase.self, from: Data(contentsOf: directory.appending(path: $0)))
        }
    }
}

/// What must hold for any answer of any model; shared by the offline tests and `RealReviseTests`.
enum ReviseInvariants {
    static func check(note: String, plan: RevisePlan, verdict: ReviseGuard.Verdict, context: String) {
        let before = MarkdownBlocks.split(note)
        let after = MarkdownBlocks.split(verdict.body)
        #expect(before.count == after.count, "\(context): the block count changed")
        // Only the applied units' blocks may differ.
        var changeable = Set<Int>()
        for item in verdict.applied { changeable.formUnion(Set(item.blockRange)) }
        for index in before.indices where !changeable.contains(index) && index < after.count {
            #expect(before[index] == after[index], "\(context): block \(index) changed outside the commented blocks")
        }
        // No image, link, HTML or other markup that the note did not have.
        let new = ReviseTokens.of(verdict.body).subtracting(ReviseTokens.of(note))
        #expect(new.isEmpty, "\(context): new markup or links \(new)")
        #expect(
            MarkdownText.strippingBidiAndControls(verdict.body) == verdict.body
                || MarkdownText.strippingBidiAndControls(note) != note, "\(context): control characters in the note")
        // The counts agree: what was applied is what changed, and a rejected or unchanged unit changed nothing.
        let touched = Set(verdict.applied.map(\.unitID))
        let others = Set(verdict.rejected.map(\.unitID)).union(verdict.unchanged.map(\.unitID))
        #expect(touched.isDisjoint(with: others), "\(context): a unit is both applied and not")
    }
}

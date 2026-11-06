import Foundation
import Testing

@testable import NotesPlugin

/// Fixtures for the Revise tests: a note, and threads anchored on a quote of it the way the popover makes them.
enum ReviseFixtures {
    static let note = """
        ## Decisions

        - Ship onboarding on 12 Nov.
        - Pricing page moves to the next sprint.

        ## Tasks

        Send the demo build to QA.

        Call the supplier about the invoice.
        """

    /// An open thread on `quote` of `text`, with its comments.
    static func thread(
        _ id: Int64, quote: String, in text: String, comments: [String] = ["Add an owner."],
        status: CommentStatus = .open
    ) throws -> CommentThread {
        let range = (text as NSString).range(of: quote)
        let anchor = try #require(CommentAnchors.make(in: text, range: range))
        let records = comments.enumerated().map { offset, body in
            CommentRecord(
                id: id * 100 + Int64(offset), docID: 1, threadID: id, author: "human",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000), body: body, anchorRevisionID: 1,
                anchor: anchor, status: status, resolvedAt: nil)
        }
        return CommentThread(threadID: id, comments: records)
    }

    static func plan(_ text: String = note, _ threads: [CommentThread]) -> RevisePlan {
        ReviseUnitPlanner.plan(head: text, threads: threads)
    }
}

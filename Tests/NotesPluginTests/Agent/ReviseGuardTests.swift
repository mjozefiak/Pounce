import Foundation
import Testing

@testable import NotesPlugin

/// Spec step 6.1: the guard table. The model's answer can only change the commented blocks, and only in a way that
/// keeps their kind, count and the absence of links, images and HTML.
@Suite struct ReviseGuardTests {
    private let head = ReviseFixtures.note

    private func plan(_ quotes: [String]) throws -> RevisePlan {
        let threads = try quotes.enumerated().map {
            try ReviseFixtures.thread(Int64($0.offset + 1), quote: $0.element, in: head)
        }
        return ReviseFixtures.plan(head, threads)
    }

    // MARK: Accepted

    @Test func aCommentedBlockIsReplacedAndEverythingElseStaysByteForByte() throws {
        let plan = try plan(["next sprint"])
        let verdict = try ReviseGuard.check(
            head: head, plan: plan,
            answer: "[[unit 1]]\n- Pricing page moves to the next sprint (owner: Marek).")
        #expect(verdict.applied.map(\.unitID) == [1])
        #expect(verdict.applied.first?.threadIDs == [1])
        #expect(verdict.changedBlockCount == 1)
        #expect(verdict.rejected.isEmpty && verdict.skipped.isEmpty)
        #expect(
            verdict.body
                == head.replacingOccurrences(
                    of: "- Pricing page moves to the next sprint.",
                    with: "- Pricing page moves to the next sprint (owner: Marek)."))
    }

    @Test func listItemsKeepTheLineBreaksBetweenThem() throws {
        // Both list items sit in one unit when a thread spans them.
        let both = try #require(
            CommentAnchors.make(in: head, range: (head as NSString).range(of: "12 Nov.\n- Pricing")))
        let record = CommentRecord(
            id: 1, docID: 1, threadID: 1, author: "human", createdAt: Date(), body: "Merge", anchorRevisionID: 1,
            anchor: both, status: .open, resolvedAt: nil)
        let plan = ReviseFixtures.plan(head, [CommentThread(threadID: 1, comments: [record])])
        #expect(plan.units.first?.blocks.count == 2)
        let verdict = try ReviseGuard.check(
            head: head, plan: plan, answer: "[[unit 1]]\n- Ship onboarding on 12 Nov.\n- Pricing moves a sprint.")
        #expect(verdict.body.contains("- Ship onboarding on 12 Nov.\n- Pricing moves a sprint.\n\n## Tasks"))
    }

    @Test func bidiAndZeroWidthCharactersAreStrippedFromTheAnswer() throws {
        let plan = try plan(["demo build"])
        let verdict = try ReviseGuard.check(
            head: head, plan: plan, answer: "[[unit 1]]\nSend the demo\u{200B} build to QA\u{202E} today.")
        #expect(verdict.body.contains("Send the demo build to QA today."))
        #expect(!verdict.body.unicodeScalars.contains { $0.value == 0x200B || $0.value == 0x202E })
    }

    @Test func severalUnitsAreAppliedAndAnotherOneRejectedWithoutLosingTheGoodOnes() throws {
        let plan = try plan(["12 Nov", "demo build", "supplier"])
        #expect(plan.units.count == 3)
        let verdict = try ReviseGuard.check(
            head: head, plan: plan,
            answer: """
                [[unit 1]]
                - Ship onboarding on 12 Nov (Ola).
                [[unit 2]]
                Send the [build](https://evil.example) to QA.
                [[unit 3]]
                Call the supplier about the invoice today.
                """)
        #expect(verdict.applied.map(\.unitID) == [1, 3])
        #expect(verdict.rejected == [ReviseGuard.Rejected(unitID: 2, threadIDs: [2], reason: .newLink)])
        #expect(verdict.body.contains("12 Nov (Ola)."))
        #expect(verdict.body.contains("Send the demo build to QA."))
        #expect(verdict.body.contains("invoice today."))
    }

    // MARK: Whole-run rejection

    @Test func anAnswerForAUnitThatWasNotAskedForRejectsTheWholeRun() throws {
        let plan = try plan(["next sprint"])
        #expect(throws: ReviseGuard.RunRejection.outsideBlockChanged) {
            try ReviseGuard.check(head: head, plan: plan, answer: "[[unit 1]]\n- Pricing moves.\n[[unit 2]]\nOther")
        }
    }

    @Test func anAnswerWithoutAnyUnitIsUnusable() throws {
        let plan = try plan(["next sprint"])
        for answer in ["", "   \n", "Sure! Here is the new text.", "- Pricing moves."] {
            #expect(throws: ReviseGuard.RunRejection.unusableAnswer) {
                try ReviseGuard.check(head: head, plan: plan, answer: answer)
            }
        }
    }

    @Test func theModelRepeatingTheContextIsAStructureChangeNotACopyIntoTheNote() throws {
        // It returned the context blocks as part of the unit: more blocks than asked for, so nothing is applied.
        let plan = try plan(["next sprint"])
        let verdict = try ReviseGuard.check(
            head: head, plan: plan,
            answer: "[[unit 1]]\n- Ship onboarding on 12 Nov.\n- Pricing page moves.\n\n## Tasks")
        #expect(verdict.applied.isEmpty)
        #expect(verdict.rejected.map(\.reason) == [.structureChanged])
        #expect(verdict.body == head)
    }

    // MARK: Block rejection

    @Test func theRejectionTable() throws {
        let plan = try plan(["next sprint"])
        let cases: [(String, ReviseGuard.BlockRejection)] = [
            ("[[unit 1]]", .empty),
            ("[[unit 1]]\n   \n", .empty),
            ("[[unit 1]]\n" + String(repeating: "- long ", count: 40), .tooLong),
            ("[[unit 1]]\nPricing page moves to the next sprint.", .structureChanged),
            ("[[unit 1]]\n## Pricing page moves to the next sprint.", .structureChanged),
            ("[[unit 1]]\n- Pricing\n- moves", .structureChanged),
            ("[[unit 1]]\n- See [the page](https://example.com) now.", .newLink),
            ("[[unit 1]]\n- See https://example.com now.", .newLink),
            ("[[unit 1]]\n- See <https://example.com> now.", .newHTML),
            ("[[unit 1]]\n- ![chart](https://example.com/c.png) next sprint.", .newImage),
            ("[[unit 1]]\n- Next sprint <script>alert(1)</script>.", .newHTML),
            ("[[unit 1]]\n- Next sprint <b>soon</b>.", .newHTML),
        ]
        for (answer, expected) in cases {
            let verdict = try ReviseGuard.check(head: head, plan: plan, answer: answer)
            #expect(verdict.rejected.map(\.reason) == [expected], "\(answer)")
            #expect(verdict.applied.isEmpty)
            #expect(verdict.body == head)
        }
    }

    @Test func aLinkTheBlockAlreadyHadIsFine() throws {
        let text = "## Links\n\nRead [the spec](https://example.com/spec) first."
        let thread = try ReviseFixtures.thread(1, quote: "Read", in: text)
        let plan = ReviseFixtures.plan(text, [thread])
        let verdict = try ReviseGuard.check(
            head: text, plan: plan, answer: "[[unit 1]]\nRead [the spec](https://example.com/spec) before Monday.")
        #expect(verdict.applied.count == 1)
    }

    @Test func aTinyBlockMayGrowToTheAllowance() throws {
        let text = "## T\n\nFix."
        let plan = ReviseFixtures.plan(text, [try ReviseFixtures.thread(1, quote: "Fix", in: text)])
        let ok = try ReviseGuard.check(
            head: text, plan: plan, answer: "[[unit 1]]\nFix the login bug before the Friday release.")
        #expect(ok.applied.count == 1)
    }

    // MARK: Human edits

    @Test func aBlockEditedAfterTheCommentIsSkippedAndReported() throws {
        // The comment was made on the old text of the block; the user rewrote it in the same session.
        let thread = try ReviseFixtures.thread(1, quote: "next sprint", in: head)
        let edited = head.replacingOccurrences(of: "moves to the next sprint", with: "waits for the next sprint")
        let plan = ReviseFixtures.plan(edited, [thread])
        #expect(plan.units.isEmpty)
        #expect(plan.skipped == [ReviseSkip(threadIDs: [1], reason: .editedAfterComment)])
    }

    @Test func aCommentThenAnEditOfTheSameBlockThenReviseSkipsItAndStillRevisesTheOthers() throws {
        let first = try ReviseFixtures.thread(1, quote: "next sprint", in: head)
        let second = try ReviseFixtures.thread(2, quote: "supplier", in: head)
        let edited = head.replacingOccurrences(of: "moves to the next sprint", with: "waits for the next sprint")
        let plan = ReviseFixtures.plan(edited, [first, second])
        #expect(plan.units.map(\.threadIDs) == [[2]])
        #expect(plan.skipped == [ReviseSkip(threadIDs: [1], reason: .editedAfterComment)])
        let verdict = try ReviseGuard.check(
            head: edited, plan: plan, answer: "[[unit 1]]\nCall the supplier about the invoice by Friday.")
        #expect(verdict.applied.map(\.threadIDs) == [[2]])
        #expect(verdict.skipped == plan.skipped)
        #expect(verdict.body.contains("waits for the next sprint"))
    }

    @Test func aBlockThatChangedBetweenPlanningAndTheCheckIsSkipped() throws {
        let plan = try plan(["next sprint"])
        let moved = head.replacingOccurrences(of: "next sprint", with: "next quarter")
        let verdict = try ReviseGuard.check(head: moved, plan: plan, answer: "[[unit 1]]\n- Pricing moves.")
        #expect(verdict.applied.isEmpty)
        #expect(verdict.skipped == [ReviseSkip(threadIDs: [1], reason: .editedAfterComment)])
        #expect(verdict.body == moved)
    }

    @Test func aThreadWhoseQuoteIsGoneIsSkippedAsChanged() throws {
        let thread = try ReviseFixtures.thread(1, quote: "supplier", in: head)
        let gone = head.replacingOccurrences(of: "supplier", with: "vendor")
        let plan = ReviseFixtures.plan(gone, [thread])
        #expect(plan.skipped == [ReviseSkip(threadIDs: [1], reason: .textChanged)])
    }

    @Test func resolvedThreadsAreNotRevised() throws {
        let thread = try ReviseFixtures.thread(1, quote: "supplier", in: head, status: .resolved)
        #expect(ReviseFixtures.plan(head, [thread]) == RevisePlan(units: [], skipped: []))
    }

    @Test func threadsTouchingTheSameBlockFormOneUnit() throws {
        let plan = try plan(["supplier", "invoice"])
        #expect(plan.units.count == 1)
        #expect(plan.units.first?.threadIDs == [1, 2])
        #expect(plan.units.first?.comments == ["Add an owner.", "Add an owner."])
    }

    @Test func aRunTooBigForTheContextDefersTheRest() throws {
        let threads = try ["12 Nov", "supplier"].enumerated().map {
            try ReviseFixtures.thread(Int64($0.offset + 1), quote: $0.element, in: head)
        }
        let plan = ReviseUnitPlanner.plan(head: head, threads: threads, inputBudget: 150)
        #expect(plan.units.count == 1)
        #expect(plan.skipped == [ReviseSkip(threadIDs: [2], reason: .deferred)])
    }

    @Test func blockKindsFollowTheFirstLine() {
        #expect(ReviseBlockKind.of("## Title") == .heading(2))
        #expect(ReviseBlockKind.of("#hash") == .paragraph)
        #expect(ReviseBlockKind.of("- [ ] todo") == .task)
        #expect(ReviseBlockKind.of("- item") == .bullet)
        #expect(ReviseBlockKind.of("3. item") == .numbered)
        #expect(ReviseBlockKind.of("> quote") == .quote)
        #expect(ReviseBlockKind.of("```\ncode\n```") == .code)
        #expect(ReviseBlockKind.of("| a | b |\n|---|---|\n| 1 | 2 |") == .table)
        #expect(ReviseBlockKind.of("plain") == .paragraph)
    }

    // MARK: Link tokens (review fix M3)

    @Test(arguments: [
        "profile: Marek", "Metadata: none", "hotel: booked", "Intel: slow", "mobile: ready", "Data: 12 May",
        "Tel: 555 0100", "Plik: notes.md", "version 1.2.3 and v2.0.1", "see notes.md or e.g. the pilot", "i.e. later",
    ])
    func wordsEndingInASchemeNameAreNoLinks(_ text: String) {
        #expect(ReviseTokens.of(text).isEmpty, "\(text)")
    }

    @Test(arguments: [
        ("see https://example.com/a", "url:https://example.com/a"), ("file:///tmp/x", "url:file:///tmp/x"),
        ("call tel:+48500100200", "url:tel:+48500100200"),
        ("data:text/plain;base64,AAA", "url:data:text/plain;base64,aaa"),
        ("(mailto:a@b.pl)", "url:mailto:a@b.pl"), ("go to www.example.com", "url:www.example.com"),
        ("example.com/path", "url:example.com/path"),
    ])
    func realLinksAreStillTokens(_ text: String, _ token: String) {
        #expect(ReviseTokens.of(text).contains(token), "\(text)")
    }

    @Test func trailingPunctuationIsNotPartOfTheLink() {
        let base = ReviseTokens.of("Spec at https://example.com/spec for now")
        for tail in [".", ",", ";", ":", "!", "?", "?!"] {
            #expect(ReviseTokens.of("Spec at https://example.com/spec\(tail) for now") == base, "tail \(tail)")
        }
        #expect(ReviseTokens.of("www.example.com.") == ReviseTokens.of("www.example.com"))
    }

    @Test func aPeriodAddedAfterAnExistingLinkIsNotANewLink() throws {
        let note = "- Spec at https://example.com/spec now"
        let thread = try ReviseFixtures.thread(1, quote: "now", in: note)
        let verdict = try ReviseGuard.check(
            head: note, plan: ReviseFixtures.plan(note, [thread]),
            answer: "[[unit 1]]\n- Spec at https://example.com/spec.")
        #expect(verdict.applied.map(\.unitID) == [1] && verdict.rejected.isEmpty)
    }
}

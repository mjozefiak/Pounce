import Foundation
import Testing

@testable import NotesPlugin

/// Spec step 5.1: anchors survive edits before them, and deleted anchor text gives "text changed". Pure logic.
@Suite struct CommentAnchorTests {
    private let text = """
        ## Decisions

        - Ship onboarding on 12 Nov.
        - Pricing page moves to the next sprint (Marek confirmed).

        ## Tasks

        Send the demo build to QA.
        """

    private func makeAnchor(_ quote: String, in text: String, occurrence: Int = 0) throws -> CommentAnchor {
        let source = text as NSString
        var found = NSRange(location: 0, length: 0)
        var from = 0
        for _ in 0...occurrence {
            found = source.range(of: quote, range: NSRange(location: from, length: source.length - from))
            from = found.location + 1
        }
        return try #require(CommentAnchors.make(in: text, range: found))
    }

    @Test func anAnchorKeepsTheQuoteItsContextAndTheBlockHash() throws {
        let anchor = try makeAnchor("next sprint", in: text)
        #expect(anchor.quote == "next sprint")
        #expect(anchor.prefix.hasSuffix("moves to the "))
        #expect(anchor.suffix.hasPrefix(" (Marek"))
        #expect(anchor.prefix.utf16.count <= CommentAnchors.contextLength)
        #expect(anchor.end - anchor.start == "next sprint".utf16.count)
        #expect(anchor.blockHash.count == 64)
        // The same block gives the same hash wherever in the block the range is; another block gives another.
        let other = try makeAnchor("Marek", in: text)
        #expect(other.blockHash == anchor.blockHash)
        #expect(try self.makeAnchor("demo build", in: text).blockHash != anchor.blockHash)
    }

    @Test func aRangeTouchingTwoBlocksHashesBothAsOneUnit() throws {
        let both = try #require(
            CommentAnchors.make(in: text, range: (text as NSString).range(of: "12 Nov.\n- Pricing")))
        let first = try makeAnchor("12 Nov", in: text)
        #expect(both.blockHash != first.blockHash)
    }

    @Test func blankOutOfRangeAndOverlongSelectionsAreRefused() {
        #expect(CommentAnchors.make(in: text, range: NSRange(location: 0, length: 0)) == nil)
        #expect(CommentAnchors.make(in: "a   b", range: NSRange(location: 1, length: 3)) == nil)
        #expect(CommentAnchors.make(in: text, range: NSRange(location: NSNotFound, length: 3)) == nil)
        #expect(CommentAnchors.make(in: text, range: NSRange(location: text.utf16.count - 2, length: 9)) == nil)
        let long = String(repeating: "a", count: CommentAnchors.maxQuoteLength + 1)
        #expect(CommentAnchors.make(in: long, range: NSRange(location: 0, length: long.utf16.count)) == nil)
    }

    @Test func contextDoesNotSplitACharacter() throws {
        let emoji = String(repeating: "x", count: 31) + "👩‍👩‍👧‍👦" + "target" + "👩‍👩‍👧‍👦" + String(repeating: "y", count: 31)
        let range = (emoji as NSString).range(of: "target")
        let anchor = try #require(CommentAnchors.make(in: emoji, range: range))
        #expect(anchor.prefix.utf16.count <= CommentAnchors.contextLength + 11)
        #expect(anchor.prefix.hasSuffix("👩‍👩‍👧‍👦") || anchor.prefix.first == "x")
        #expect(AnchorResolver.resolve(anchor, in: emoji) == .found(range))
    }

    // MARK: Resolving

    @Test func anAnchorSurvivesEditsBeforeIt() throws {
        let anchor = try makeAnchor("next sprint", in: text)
        let edited = "## Notes of the day\n\nA new first paragraph, longer than the one before.\n\n" + text
        let resolved = AnchorResolver.resolve(anchor, in: edited)
        let range = try #require(resolved.range)
        #expect((edited as NSString).substring(with: range) == "next sprint")
        #expect(range.location > anchor.start)
    }

    @Test func anAnchorSurvivesEditsAfterIt() throws {
        let anchor = try makeAnchor("next sprint", in: text)
        let edited = text + "\n\nOne more line at the end."
        #expect(AnchorResolver.resolve(anchor, in: edited) == .found(NSRange(location: anchor.start, length: 11)))
    }

    @Test func deletedAnchorTextGivesTextChanged() throws {
        let anchor = try makeAnchor("next sprint", in: text)
        let edited = text.replacingOccurrences(of: "next sprint", with: "week 46")
        #expect(AnchorResolver.resolve(anchor, in: edited) == .changed)
        #expect(AnchorResolver.resolve(anchor, in: "") == .changed)
        // A quote edited in the middle is changed too: the quote is what is looked for.
        let typo = text.replacingOccurrences(of: "next sprint", with: "next spring")
        #expect(AnchorResolver.resolve(anchor, in: typo) == .changed)
    }

    @Test func severalMatchesPickTheOneWithMatchingContext() throws {
        let repeated = "Call Kasia on Monday.\n\nCall Marek on Tuesday.\n\nCall Kasia on Friday."
        // The comment was made on the LAST "Call": its prefix and suffix tell it from the others.
        let anchor = try makeAnchor("Call", in: repeated, occurrence: 2)
        #expect(anchor.suffix.hasPrefix(" Kasia on Friday"))
        let moved = "Intro.\n\nOutro.\n\n" + repeated
        let range = try #require(AnchorResolver.resolve(anchor, in: moved).range)
        #expect((moved as NSString).substring(from: range.location).hasPrefix("Call Kasia on Friday"))
    }

    @Test func whenContextTiesTheNearestToTheOriginalOffsetWins() throws {
        let repeated = "same\n\nsame\n\nsame"
        let anchor = try makeAnchor("same", in: repeated, occurrence: 1)
        let range = try #require(AnchorResolver.resolve(anchor, in: repeated).range)
        #expect(range.location == anchor.start)
    }

    @Test func theSearchIsLiteralAndCaseSensitive() throws {
        let anchor = try makeAnchor("Marek", in: text)
        #expect(AnchorResolver.resolve(anchor, in: text.replacingOccurrences(of: "Marek", with: "marek")) == .changed)
    }

    @Test func aManyMatchQuoteStaysBounded() throws {
        let many = String(repeating: "a ", count: 20_000)
        let anchor = try #require(CommentAnchors.make(in: many, range: NSRange(location: 100, length: 1)))
        #expect(AnchorResolver.resolve(anchor, in: many).range != nil)
    }

    @Test func aDeletedShortQuoteDoesNotJumpToAnotherOccurrence() throws {
        let original = "Is the date fine?\n\nok\n\nThe book is long."
        let anchor = try makeAnchor("ok", in: original)
        // The commented passage is deleted; the only "ok" left is inside "book", far away and in other context.
        let edited = "Is the date fine?\n\nThe book is long."
        #expect(AnchorResolver.resolve(anchor, in: edited) == .changed)
        // The same quote with its neighbours intact is found, also after an edit elsewhere.
        let moved = "Intro.\n\n" + original
        #expect(AnchorResolver.resolve(anchor, in: moved).range != nil)
    }

    @Test func aLoneMatchWithAMatchingBlockOrALongQuoteIsKept() throws {
        let original = "Intro.\n\nAgree: ok\n\nEnd."
        let anchor = try makeAnchor("ok", in: original)
        // Both sides of the quote were edited, but its block hash... changed too: no trust, so text changed.
        #expect(AnchorResolver.resolve(anchor, in: "Intro.\n\nSure: ok!\n\nEnd.") == .changed)
        // A long quote is distinctive: its lone match is the passage even when the context changed.
        let long = "the migration finishes before the Friday release"
        let text = "Plan: \(long). Done."
        let longAnchor = try makeAnchor(long, in: text)
        #expect(AnchorResolver.resolve(longAnchor, in: "Totally new start \(long) and new ending").range != nil)
        // The block hash of an untouched block also vouches for a short quote whose context was cut.
        let block = "- ok"
        let blockAnchor = try makeAnchor("ok", in: block)
        #expect(AnchorResolver.resolve(blockAnchor, in: "# New\n\n- ok").range != nil)
    }

    @Test func aMatchNeverStartsOrEndsInsideAComposedCharacter() throws {
        let anchor = try makeAnchor("e", in: "a e b")
        // "é" written as e + combining acute is one character: the quote "e" is not in it.
        #expect(AnchorResolver.resolve(anchor, in: "caf\u{65}\u{301} only") == .changed)
        #expect(AnchorResolver.resolve(anchor, in: "a e b").range != nil)
        let emojiAnchor = try makeAnchor("\u{1F468}", in: "x \u{1F468} y")
        #expect(AnchorResolver.resolve(emojiAnchor, in: "x \u{1F468}\u{200D}\u{1F469} y") == .changed)
    }

    @Test func manyMatchesScoreOnlyTheNearestOnes() throws {
        let many = String(repeating: "ab ", count: 8000)
        let anchor = try #require(CommentAnchors.make(in: many, range: NSRange(location: 300, length: 1)))
        let range = try #require(AnchorResolver.resolve(anchor, in: many).range)
        #expect(abs(range.location - 300) < 200)
    }

    @Test func threadsGroupByIdWithRepliesAfterTheirComment() {
        func record(_ id: Int64, thread: Int64, status: CommentStatus = .open) -> CommentRecord {
            CommentRecord(
                id: id, docID: 1, threadID: thread, author: "human", createdAt: Date(timeIntervalSince1970: Double(id)),
                body: "c\(id)", anchorRevisionID: 1,
                anchor: CommentAnchor(start: 0, end: 1, blockHash: "h", quote: "q", prefix: "", suffix: ""),
                status: status, resolvedAt: nil)
        }
        let threads = CommentThreads.group([record(1, thread: 1), record(2, thread: 2), record(3, thread: 1)])
        #expect(threads.map(\.id) == [1, 2])
        #expect(threads[0].comments.map(\.id) == [1, 3])
        #expect(threads[0].replies.map(\.id) == [3])
        #expect(threads[1].isOpen)
    }
}

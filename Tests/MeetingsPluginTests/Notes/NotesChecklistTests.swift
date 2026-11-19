import Foundation
import Testing

@testable import MeetingsPlugin

@Suite struct NotesChecklistTests {
    @Test func aTaskIsAChecklistItemAndNothingElseKeepsItsBrackets() {
        let rendered = NotesMarkdown.render("- [ ] Send the offer\n- [x] Book the room\n- [link](http://evil.example)")
        #expect(rendered == "- [ ] Send the offer\n- [x] Book the room\n- \\[link\\]\\(http\\://evil.example\\)")
    }

    @Test func composedNotesHaveNoTimesAndTasksAreChecklists() {
        let task = NotesPoint(
            id: "p1", kind: .task, timeMs: 34_000, quote: "q", text: "Send the offer.", person: "Marek", due: "Friday")
        let verdict = NotesGuard.ReduceVerdict(
            decisions: [NotesPoint(id: "p2", kind: .decision, timeMs: 83_000, quote: "q", text: "Ship it.")],
            tasks: [task], questions: [], summary: nil, summaryReplaced: false, rejectedIDs: 0)
        let markdown = NotesComposer.markdown(verdict: verdict, participants: ["Anna", "Marek"], labels: .english)
        #expect(markdown.contains("- [ ] Send the offer. — owner\\: Marek, due\\: Friday"))
        #expect(markdown.contains("### Participants\n\nAnna, Marek"))
        #expect(markdown.firstMatch(of: /\d{1,2}\\:\d\d/) == nil)
    }

    @Test func namesAndModelTextCannotChangeTheStructure() {
        let task = NotesPoint(id: "p1", kind: .task, timeMs: 1, quote: "q", text: "[ ] Send it [10:15]", person: "A")
        let decision = NotesPoint(id: "p2", kind: .decision, timeMs: 1, quote: "q", text: "[x] Ship it (10:15)")
        let verdict = NotesGuard.ReduceVerdict(
            decisions: [decision], tasks: [task], questions: [], summary: nil, summaryReplaced: false,
            rejectedIDs: 0)
        let markdown = NotesComposer.markdown(verdict: verdict, participants: ["# Boss", "1. Anna"], labels: .english)
        #expect(markdown.contains("- [ ] Send it — owner\\: A"))
        #expect(markdown.contains("- Ship it\n"))
        #expect(!markdown.contains("[x]") && !markdown.contains("10:15") && !markdown.contains("10\\:15"))
        #expect(markdown.hasSuffix("### Participants\n\nBoss, 1. Anna"))
        #expect(markdown.split(separator: "\n").filter { $0.hasPrefix("#") }.allSatisfy { $0.hasPrefix("###") })
    }
}

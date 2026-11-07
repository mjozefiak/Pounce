import AppKit
import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// Typing latency of the editor's text path (budget: p99 < 8 ms at 50 000 characters, ADR 0008 addendum 0.1).
/// Off by default: `LINTEL_BENCHMARKS=1 swift test -c release -Xswiftc -enable-testing --filter EditorBenchmarks`.
///
/// This measures what runs on every keystroke without a window: the character insert, the block scan and the
/// restyle of the edited block, plus the `onEdit` callback (a Swift `String` of the whole text). It does NOT
/// include layout and drawing, the key event path or the compositor: the number that counts for the budget is
/// measured in a real window (see `docs/perf.md`).
@Suite(
    "EditorBenchmarks", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LINTEL_BENCHMARKS"] != nil))
@MainActor
struct EditorBenchmarks {
    @Test("typing at 50 000 characters: insert, scan and block restyle per keystroke")
    func typing() throws {
        var parts: [String] = []
        var count = 0
        var index = 0
        while count < 50_000 {
            let block = "Paragraph \(index) with **bold**, *italic*, `code` and a [link](https://example.com) in it."
            parts.append(index % 7 == 0 ? "## Heading \(index)" : block)
            count += parts[parts.count - 1].count + 2
            index += 1
        }
        let controller = NoteEditorController(pasteboard: RecordingPasteboard())
        controller.setText(parts.joined(separator: "\n\n"))
        var reported = 0
        controller.onEdit = { reported &+= $0.text.utf8.count }
        let view = controller.textView
        let clock = ContinuousClock()
        for position in [0.0, 0.5, 1.0] {
            var samples: [Double] = []
            var location = Int(Double(view.string.utf16.count - 40) * position) + 10
            for _ in 0..<300 {
                view.setSelectedRange(NSRange(location: location, length: 0))
                let elapsed = clock.measure {
                    view.insertText("a", replacementRange: NSRange(location: location, length: 0))
                }
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
                location += 1
            }
            samples.sort()
            func at(_ q: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * q))] }
            print(
                "typing \(Int(position * 100))% of \(view.string.count) chars: median \(at(0.5)) ms, p95 \(at(0.95)) ms, p99 \(at(0.99)) ms, max \(samples.last ?? 0) ms"
            )
            #expect(at(0.99) < 8)
        }
        #expect(reported > 0)
    }
}

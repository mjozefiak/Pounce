#if DEBUG
import AppKit
import PounceKit

/// DEBUG builds only: fake history entries for QA screenshots (`plugins.clipboard.qaSeed=demo`,
/// `docs/qa.md`). Seeding only fills an empty history, so it never mixes with real entries; in QA the
/// data root is a temporary folder and the key is in an in-memory keychain.
enum ClipboardQASeed {
    static func drafts(now: Date) -> [ClipDraft] {
        func text(_ value: String) -> [PasteboardItem] {
            [
                PasteboardItem(representations: [
                    PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: Data(value.utf8))
                ])
            ]
        }
        func draft(
            _ kind: ClipKind, _ preview: String, _ items: [PasteboardItem], _ app: (String, String)?, minutesAgo: Double
        ) -> ClipDraft {
            ClipDraft(
                kind: kind,
                previewText: preview,
                items: items,
                sourceBundleID: app?.0,
                sourceAppName: app?.1,
                capturedAt: now.addingTimeInterval(-minutesAgo * 60)
            )
        }
        let textEdit = ("com.apple.TextEdit", "TextEdit")
        let safari = ("com.apple.Safari", "Safari")
        let notes = ("com.apple.Notes", "Notes")
        let finder = ("com.apple.finder", "Finder")
        let link = "https://example.com/pounce/release-notes"
        let note = "Meeting notes\nDemo the launcher on Friday.\nBring the release checklist."
        let paths = ["/tmp/pounce-demo/Quarterly Report.pdf", "/tmp/pounce-demo/Budget.numbers"]
        let fileItems = paths.map { path in
            PasteboardItem(representations: [
                PasteboardRepresentation(type: "public.file-url", data: Data(URL(filePath: path).absoluteString.utf8))
            ])
        }
        var drafts = [
            draft(
                .text, "Pounce keeps your clipboard on this Mac.", text("Pounce keeps your clipboard on this Mac."),
                textEdit, minutesAgo: 2),
            draft(.url, link, text(link), safari, minutesAgo: 9),
            draft(.text, note, text(note), notes, minutesAgo: 34),
            draft(.file, paths.joined(separator: "\n"), fileItems, finder, minutesAgo: 75),
            draft(.text, "Zażółć gęślą jaźń", text("Zażółć gęślą jaźń"), textEdit, minutesAgo: 180),
            draft(
                .text, "let greeting = \"Hello, Pounce\"", text("let greeting = \"Hello, Pounce\""), nil,
                minutesAgo: 60 * 26),
        ]
        if let png = demoPNG() {
            let items = [PasteboardItem(representations: [PasteboardRepresentation(type: "public.png", data: png)])]
            drafts.append(draft(.image, "320 × 200", items, ("com.apple.Preview", "Preview"), minutesAgo: 20))
        }
        return drafts
    }

    /// A small generated picture (no file from disk).
    static func demoPNG() -> Data? {
        let size = NSSize(width: 320, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [.systemIndigo, .systemTeal])?.draw(in: rect, angle: 30)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 120, y: 60, width: 80, height: 80)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension ClipboardPlugin {
    /// Seeds the fake entries when `qaSeed` asks for them and the history is empty.
    func seedForQA() async {
        guard settings.qaSeed == "demo", let store else { return }
        let drafts = ClipboardQASeed.drafts(now: Date())
        await Task.detached(priority: .userInitiated) {
            guard (try? store.count()) == 0 else { return }
            for draft in drafts.sorted(by: { $0.capturedAt < $1.capturedAt }) {
                _ = try? store.insert(draft)
            }
        }.value
    }
}
#endif

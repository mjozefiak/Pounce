import Foundation
import Testing

/// The Notes views draw every colour through `LintelBrand` (colours only through the brand tokens, no raw
/// colours): no named system colour, no `Color(red:…)`, no `NSColor`.
@Suite struct NotesUIScanTests {
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static let pattern =
        #"\.(red|green|blue|orange|yellow|pink|purple|indigo|teal|mint|cyan|brown|gray|black|white|primary)\b(?!\()|Color\((red|white|hue|\.sRGB|nsColor)|NSColor\.|\bNSColor\("#

    @Test func theViewsUseNoRawColour() throws {
        let folder = Self.root.appending(path: "Sources/NotesPlugin/UI")
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var count = 0
        var offences: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            count += 1
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.range(of: Self.pattern, options: .regularExpression) != nil {
                    offences.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(count >= 6)
        #expect(offences.isEmpty, "colours come from LintelBrand: \(offences)")
    }

    @Test func thePatternCatchesRawColours() {
        for bad in [".foregroundStyle(.red)", "Color.black", "Color(red: 1, green: 0, blue: 0)", "NSColor.white"] {
            #expect(bad.range(of: Self.pattern, options: .regularExpression) != nil, "\(bad)")
        }
        for good in [".foregroundStyle(LintelBrand.ink)", "Color.clear", ".font(textSize.font(.callout))"] {
            #expect(good.range(of: Self.pattern, options: .regularExpression) == nil, "\(good)")
        }
    }
}

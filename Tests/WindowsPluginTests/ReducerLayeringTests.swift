import Foundation
import Testing

@testable import WindowsPlugin

/// The reducer's parts form layers: a part never calls a function that is declared only in a part below it, so
/// there is no call web between them. The layers are read from the sources themselves (declared function names,
/// comments and strings stripped), so a rename or a comment cannot evade or trip the check.
@Suite struct ReducerLayeringTests {
    /// Top to bottom: each part may call itself and the ones above it, and the shared base (`ReducerContext`).
    private let layers = [
        "LayoutPlanner", "ReducerContext+Layout", "ReducerContext+Parking", "ReducerContext+Windows",
        "ReducerContext+Results", "ReducerContext+Commands",
    ]

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appending(path: "Sources/WindowsPlugin/Engine/Reducer/\(name).swift")
        return Self.stripped(try String(contentsOf: url, encoding: .utf8))
    }

    /// The code without `//` comments (doc comments included) and without string literals.
    static func stripped(_ text: String) -> String {
        var result = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var code = String(line)
            if let comment = code.range(of: "//") { code = String(code[..<comment.lowerBound]) }
            code = code.replacingOccurrences(of: "\"[^\"]*\"", with: "\"\"", options: .regularExpression)
            result += code + "\n"
        }
        return result
    }

    private func declaredFunctions(in text: String) -> Set<String> {
        let pattern = try? NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let range = NSRange(text.startIndex..., in: text)
        var names = Set<String>()
        for match in pattern?.matches(in: text, range: range) ?? [] {
            if let name = Range(match.range(at: 1), in: text) { names.insert(String(text[name])) }
        }
        return names
    }

    /// Whether the text calls `name` on itself (`name(...)`), not as a member of another object (`other.name(...)`).
    private func calls(_ name: String, in text: String) -> Bool {
        text.range(of: #"(?<![\w.])\#(name)\("#, options: .regularExpression) != nil
    }

    @Test func noPartCallsAFunctionThatOnlyAPartBelowItDeclares() throws {
        let texts = try Dictionary(uniqueKeysWithValues: layers.map { ($0, try source($0)) })
        let declared = texts.mapValues(declaredFunctions)
        let base = declaredFunctions(in: try source("ReducerContext"))
        for (index, layer) in layers.enumerated() {
            let allowed = layers[...index].reduce(into: base) { $0.formUnion(declared[$1] ?? []) }
            let below = layers[(index + 1)...].reduce(into: Set<String>()) { $0.formUnion(declared[$1] ?? []) }
            for name in below.subtracting(allowed) {
                #expect(
                    !calls(name, in: texts[layer] ?? ""),
                    "\(layer) must not call \(name), which only a lower part declares"
                )
            }
        }
    }

    @Test func theCheckSeesThroughCommentsAndStrings() {
        let code = Self.stripped("let a = 1 // request(1)\nlet b = \"request(2)\"\nrequest(3)")
        #expect(calls("request", in: code))
        #expect(!calls("request", in: Self.stripped("// request(1)\nlet b = \"request(2)\"")))
    }
}

import Foundation
import Testing

/// `CHANGELOG.md` feeds the release body, the appcast and "What's new", so its heading shape is a contract
/// (updates and open-source hygiene spec, decision D9): `## [Unreleased]` first, then `## [x.y.z] - YYYY-MM-DD` (or `x.y.z-beta.N`)
/// sections with `### Added|Changed|Fixed|Removed|Security`.
@Suite struct ChangelogTests {
    private static let categories: Set<String> = ["Added", "Changed", "Fixed", "Removed", "Security"]

    private func lines() throws -> [String] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "CHANGELOG.md"), encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    private func sectionHeadings() throws -> [String] {
        try lines().filter { $0.hasPrefix("## ") }
    }

    @Test func unreleasedComesFirst() throws {
        #expect(try sectionHeadings().first == "## [Unreleased]")
    }

    @Test func everyOtherSectionIsAVersionWithADate() throws {
        let pattern = /^## \[\d+\.\d+\.\d+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?\] - \d{4}-\d{2}-\d{2}$/
        for heading in try sectionHeadings().dropFirst() {
            #expect(heading.wholeMatch(of: pattern) != nil, "Bad section heading: \(heading)")
        }
    }

    @Test func versionsAreUniqueAndNotOlderBeforeNewer() throws {
        let versions = try sectionHeadings().dropFirst().compactMap { heading -> [Int]? in
            guard let match = heading.firstMatch(of: /\[(\d+)\.(\d+)\.(\d+)/) else { return nil }
            return [Int(match.1), Int(match.2), Int(match.3)].compactMap { $0 }
        }
        let names = try sectionHeadings().dropFirst().compactMap { heading in
            heading.firstMatch(of: /\[([^\]]+)\]/).map { String($0.1) }
        }
        #expect(Set(names).count == names.count, "A version appears twice")
        for (newer, older) in zip(versions, versions.dropFirst()) {
            #expect(newer.lexicographicallyPrecedes(older) == false, "Sections are not newest first")
        }
    }

    @Test func subsectionsUseTheKeepAChangelogCategories() throws {
        for line in try lines() where line.hasPrefix("### ") {
            #expect(Self.categories.contains(String(line.dropFirst(4))), "Unknown category: \(line)")
        }
    }

    /// Unreleased may be empty (right after a release); a released section may not, because
    /// `scripts/changelog-section.sh` refuses an empty one and the tag build would fail.
    @Test func everyVersionedSectionHasAnEntry() throws {
        let all = try lines()
        for (index, heading) in all.enumerated() where heading.hasPrefix("## ") && heading != "## [Unreleased]" {
            let body = all[(index + 1)...].prefix { !$0.hasPrefix("## ") }
            #expect(body.contains { $0.hasPrefix("- ") }, "Empty section: \(heading)")
        }
    }
}

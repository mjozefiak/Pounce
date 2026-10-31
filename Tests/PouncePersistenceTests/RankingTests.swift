import Foundation
import GRDB
import PounceCore
import PounceKit
import Testing

@testable import PouncePersistence

private func candidate(_ title: String, _ query: NormalizedQuery) -> Candidate? {
    guard let match = FuzzyMatcher.match(query, in: NormalizedText(title)) else { return nil }
    return Candidate(
        itemKey: ItemKey(pluginID: "apps", key: "com.example.\(title.lowercased())"),
        title: title,
        icon: .symbol("app"),
        match: match
    )
}

/// `ranking.sqlite` and the `Ranker` together (spec step 1.6). A class, so `deinit` removes the
/// temporary directory.
@Suite final class RankingTests {
    let directory: URL
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "pounce-ranking-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func ranked(_ titles: [String], query raw: String, repository: UsageRepository, at now: Date) async throws
        -> [String]
    {
        let query = TextNormalizer.query(raw)
        let candidates = titles.compactMap { candidate($0, query) }
        let stats = try await repository.stats(
            for: candidates.map(\.itemKey),
            queryPrefix: Ranker.queryPrefix(query.normalized)
        )
        return Ranker(now: now).rank(candidates, stats: stats).map(\.title)
    }

    @Test func frecencyReordersWithinATierButNeverBeatsAnExactMatch() async throws {
        let repository = try UsageRepository.open(
            at: directory.appending(path: UsageRepository.fileName),
            halfLife: Ranker.frecencyHalfLife,
            now: start
        )
        let titles = ["TextEdit", "Terminal", "Te"]

        let before = try await ranked(titles, query: "te", repository: repository, at: start)
        #expect(before == ["Te", "Terminal", "TextEdit"] || before == ["Te", "TextEdit", "Terminal"])

        let terminal = ItemKey(pluginID: "apps", key: "com.example.terminal")
        let textEdit = ItemKey(pluginID: "apps", key: "com.example.textedit")
        try await repository.recordUse(of: textEdit, queryPrefix: "tex", at: start)
        for minute in 1...3 {
            try await repository.recordUse(
                of: terminal, queryPrefix: "te", at: start.addingTimeInterval(60 * Double(minute)))
        }

        let after = try await ranked(titles, query: "te", repository: repository, at: start.addingTimeInterval(3600))
        #expect(after == ["Te", "Terminal", "TextEdit"])

        let exact = try await ranked(
            titles, query: "textedit", repository: repository, at: start.addingTimeInterval(3600))
        #expect(exact.first == "TextEdit")
    }

    @Test func recordsUsesFrecencyAndPrefixes() async throws {
        let repository = try UsageRepository.inMemory(halfLife: Ranker.frecencyHalfLife)
        let key = ItemKey(pluginID: "apps", key: "com.apple.Terminal")
        try await repository.recordUse(of: key, queryPrefix: "termi", at: start)
        try await repository.recordUse(
            of: key, queryPrefix: "te", at: start.addingTimeInterval(Ranker.frecencyHalfLife))

        let stats = try #require(try await repository.stats(for: [key], queryPrefix: "te")[key])
        #expect(stats.useCount == 2)
        #expect(abs(stats.frecency - 1.5) < 0.0001)
        #expect(stats.lastUsedAt == start.addingTimeInterval(Ranker.frecencyHalfLife))
        #expect(stats.queryAssociationCount == 2)

        let longer = try #require(try await repository.stats(for: [key], queryPrefix: "termin")[key])
        #expect(longer.queryAssociationCount == 1)
        let unrelated = try #require(try await repository.stats(for: [key], queryPrefix: "x")[key])
        #expect(unrelated.queryAssociationCount == 0)
        #expect(try await repository.stats(for: [], queryPrefix: nil).isEmpty)
        #expect(UsageRepository.prefixes(of: "terminal") == ["t", "te", "ter", "term"])
        #expect(UsageRepository.prefixes(of: nil).isEmpty)
    }

    @Test func rankerDecaysFrecencyWithTheSameHalfLife() {
        let ranker = Ranker(now: start.addingTimeInterval(2 * Ranker.frecencyHalfLife))
        let stats = UsageStats(frecency: 4, lastUsedAt: start, useCount: 4, queryAssociationCount: 0)
        #expect(abs(ranker.decayedFrecency(stats) - 1) < 0.0001)
        #expect(Ranker.queryPrefix("terminal") == "term")
        #expect(Ranker.queryPrefix("") == nil)
    }

    @Test func openingPrunesOldAssociationsAndSetsPermissions() async throws {
        let url = directory.appending(path: UsageRepository.fileName)
        let key = ItemKey(pluginID: "files", key: "/tmp/a:b")
        do {
            let repository = try UsageRepository.open(at: url, halfLife: Ranker.frecencyHalfLife, now: start)
            try await repository.recordUse(of: key, queryPrefix: "a", at: start)
        }
        let later = start.addingTimeInterval(UsageRepository.associationRetention + 60)
        let reopened = try UsageRepository.open(at: url, halfLife: Ranker.frecencyHalfLife, now: later)
        let stats = try #require(try await reopened.stats(for: [key], queryPrefix: "a")[key])
        #expect(stats.useCount == 1)
        #expect(stats.queryAssociationCount == 0)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let hasTable = try await DatabaseQueue(path: url.path).read { db in try db.tableExists("usage_stat") }
        #expect(hasTable)
    }

    @Test func recentListsOnlyUsedItemsByFrecency() {
        let items = ["Alpha", "Beta", "Gamma"].map {
            Candidate(
                itemKey: ItemKey(pluginID: "apps", key: $0), title: $0, icon: .symbol("app"),
                match: MatchResult(tier: .exact, score: 0))
        }
        let stats: [ItemKey: UsageStats] = [
            items[0].itemKey: UsageStats(frecency: 1, lastUsedAt: start, useCount: 1, queryAssociationCount: 0),
            items[2].itemKey: UsageStats(frecency: 5, lastUsedAt: start, useCount: 5, queryAssociationCount: 0),
        ]
        let recent = Ranker(now: start).recent(items, stats: stats, limit: 8)
        #expect(recent.map(\.title) == ["Gamma", "Alpha"])
        #expect(Ranker(now: start).recent(items, stats: stats, limit: 1).map(\.title) == ["Gamma"])
    }
}

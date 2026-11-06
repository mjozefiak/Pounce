import Foundation
import LintelKit
import os

/// The read side of Notes: merges what the active plugins' `NoteSource`s list with Notes' own manual notes and
/// overlay metadata into explorer rows (spec "Code layout", step 3.1).
///
/// - Every source is asked under its own budget (150 ms, on the injected clock); one that throws or overruns is
///   `unavailable` for that page and costs only its own rows. Any throw means "unknown": it never reports a note
///   as gone and never detaches anything.
/// - Sources list newest first and page by their own cursor; the library keeps a small buffer per source and
///   merges by start time, so its cursor pages across all of them.
/// - A key is routed to the source whose `pluginID` it carries. Items whose key belongs to another plugin, and a
///   repeated key, are dropped and counted in the log (ids only, never text).
/// - The library never writes. It detaches only through `OverlayDetacher`, and only for an overlay whose
///   recorded start differs from the source's (before the row is shown) or, in the sweep, for a key an OPEN
///   source's `exists` does not return.
/// - Manual notes, detached overlays and kept overlays of an off source come from the `OverlayIndex` and are not
///   part of a text query here (the full-text hits of `notes.sqlite` come with step 4.0).
actor NoteLibrary {
    private let provider: @MainActor @Sendable () -> [any NoteSource]
    private let overlays: any OverlayIndex
    private let detacher: any OverlayDetacher
    private let clock: any Clock<Duration>
    private let budget: Duration
    private let logger: Logger

    private var sources = NoteSourceSet([])
    private var generation = 0
    private var hasLoadedSources = false
    private var loading: Task<Void, Never>?
    private var reportedDrops = Set<NoteSourceSet.Drop>()
    /// Overlays whose `startedAt` no longer matches the source but whose detach threw (a newer schema, a locked
    /// store): shown as detached ("Recording removed") in memory, by `docID`, so the old text is never shown as
    /// the live note's and a kept one is not lost from the list. A later successful detach makes the store the
    /// owner of the row again.
    private var detachedInMemory: [Int64: OverlayRecord] = [:]

    init(
        sources provider: @escaping @MainActor @Sendable () -> [any NoteSource], overlays: any OverlayIndex,
        detacher: any OverlayDetacher, clock: any Clock<Duration> = ContinuousClock(),
        budget: Duration = SourceFanOut.defaultBudget,
        logger: Logger = Logger(subsystem: "com.lintelapp", category: "notes.library")
    ) {
        self.provider = provider
        self.overlays = overlays
        self.detacher = detacher
        self.clock = clock
        self.budget = budget
        self.logger = logger
    }

    // MARK: Sources

    /// Reads the active sources again (a plugin was switched on or off). Cursors made before this start over.
    func refreshSources() async {
        let raw = await provider()
        let set = NoteSourceSet(raw)
        for drop in set.dropped where reportedDrops.insert(drop).inserted {
            switch drop {
            case .duplicate(let id): logger.error("note source dropped: duplicate id \(id.rawValue, privacy: .public)")
            case .invalidID(let id): logger.error("note source dropped: invalid id \(id.rawValue, privacy: .public)")
            }
        }
        // The same sources again (a plugin toggled elsewhere): the cursors stay good, so no page restarts.
        if hasLoadedSources, set.isSame(as: sources) { return }
        sources = set
        generation += 1
        hasLoadedSources = true
    }

    /// The first read of the set, shared by calls that arrive together (a second read would start every cursor over).
    private func ensureSources() async {
        if hasLoadedSources { return }
        if let loading {
            await loading.value
            return
        }
        let task = Task { await refreshSources() }
        loading = task
        await task.value
        loading = nil
    }

    /// The plugins whose sources the library uses, in the order the shell handed them over.
    var activePluginIDs: [PluginID] { sources.order }

    /// The source that owns a key, or `nil` when its plugin has none (off, failed, dropped).
    func source(for key: NoteKey) async -> (any NoteSource)? {
        await ensureSources()
        return sources.accepted[key.pluginID]
    }

    /// One stream that yields when any source says its notes changed or the set of sources changed. Pass the
    /// context's `noteSourcesChanged()` stream. The library has already read the new set when it yields; a source's own change stream is followed from the
    /// first read on.
    nonisolated func changes(sourceSetChanges: AsyncStream<Void>) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task { [weak self] in
            var watchers: [Task<Void, Never>] = []
            func restart() async {
                for watcher in watchers { watcher.cancel() }
                guard let self else { return }
                await self.refreshSources()
                let current = await self.currentSources()
                watchers = current.map { source in
                    Task {
                        for await _ in source.makeChanges() { continuation.yield() }
                    }
                }
            }
            await restart()
            for await _ in sourceSetChanges {
                if Task.isCancelled { break }
                await restart()
                continuation.yield()
            }
            for watcher in watchers { watcher.cancel() }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func currentSources() -> [any NoteSource] {
        sources.order.compactMap { sources.accepted[$0] }
    }

    // MARK: Listing

    /// One page of rows, newest first. `after` is the `next` of the previous page.
    func list(matching query: NormalizedQuery?, after: NoteListCursor?, limit: Int) async -> NoteListing {
        await ensureSources()
        let size = max(1, limit)
        let text = (query?.isEmpty == false) ? query : nil
        let currentGeneration = generation
        let accepted = sources
        var restarted = false
        var cursor = after
        if let existing = after, existing.generation != currentGeneration {
            cursor = nil
            restarted = true
        }
        var progress = cursor?.sources ?? [:]
        var unavailable: [UnavailableSource] = []
        var overlaysAvailable = true

        // 1. Fill every source's buffer, all of them at once, each under its budget.
        let fills = await fill(accepted, progress: progress, query: text, size: size)
        for fill in fills {
            var state = progress[fill.pluginID] ?? SourceProgress()
            state.next = fill.next
            state.exhausted = fill.exhausted
            state.total = fill.total ?? state.total
            if !fill.fetched.isEmpty {
                let resolved = await resolve(fill.fetched)
                if !resolved.overlaysAvailable { overlaysAvailable = false }
                state.buffer.append(contentsOf: resolved.items)
                state.buffer.sort {
                    NoteSortPosition(date: $0.summary.startedAt, tie: $0.summary.id.rawValue).isBefore(
                        NoteSortPosition(date: $1.summary.startedAt, tie: $1.summary.id.rawValue))
                }
            }
            if let reason = fill.failure {
                unavailable.append(UnavailableSource(pluginID: fill.pluginID, reason: reason))
            } else if state.buffer.isEmpty, !state.exhausted {
                // Pages without items that never end: treat it as not answering rather than loop.
                unavailable.append(UnavailableSource(pluginID: fill.pluginID, reason: .failed))
            }
            progress[fill.pluginID] = state
        }
        let down = Set(unavailable.map(\.pluginID))

        // 2. Notes' own rows (manual, detached, kept overlays of a source that is off or did not answer).
        let live = Set(accepted.order).subtracting(down)
        var local: [NoteRow] = []
        if text == nil {
            let rows = await localRows(excludingPlugins: live)
            local = rows.rows
            if !rows.available { overlaysAvailable = false }
        }
        let localCount = local.count
        let boundary = cursor?.boundary
        local = local.filter { row in boundary.map { $0.isBefore(NoteSortPosition(row)) } ?? true }
        local.sort { NoteSortPosition($0).isBefore(NoteSortPosition($1)) }

        // 3. Merge the heads until the page is full.
        var rows: [NoteRow] = []
        var emitted = Set<NoteItemID>()
        var localIndex = 0
        while rows.count < size {
            var best: (position: NoteSortPosition, plugin: PluginID?)?
            for id in accepted.order {
                guard let head = progress[id]?.buffer.first else { continue }
                let position = NoteSortPosition(date: head.summary.startedAt, tie: head.summary.id.rawValue)
                if let current = best, !position.isBefore(current.position) { continue }
                best = (position, id)
            }
            if localIndex < local.count {
                let position = NoteSortPosition(local[localIndex])
                if let current = best, !position.isBefore(current.position) {
                    // A source's head is earlier: keep it.
                } else {
                    best = (position, nil)
                }
            }
            guard let chosen = best else { break }
            if let plugin = chosen.plugin, var state = progress[plugin] {
                let item = state.buffer.removeFirst()
                progress[plugin] = state
                let row = Self.row(for: item)
                if emitted.insert(row.id).inserted { rows.append(row) }
            } else {
                let row = local[localIndex]
                localIndex += 1
                if emitted.insert(row.id).inserted { rows.append(row) }
            }
        }

        // 4. The cursor, and the total.
        let remainingLocal = localIndex < local.count
        let moreFromSources = accepted.order.contains { id in
            guard let state = progress[id] else { return false }
            return !state.buffer.isEmpty || (!state.exhausted && !down.contains(id))
        }
        let next: NoteListCursor? =
            (remainingLocal || moreFromSources)
            ? NoteListCursor(
                generation: currentGeneration, boundary: rows.last.map(NoteSortPosition.init) ?? boundary,
                sources: progress)
            : nil
        let total = progress.values.reduce(0) { $0 + $1.total } + localCount
        return NoteListing(
            rows: rows, next: next, total: total, unavailable: unavailable, overlaysAvailable: overlaysAvailable,
            restarted: restarted)
    }

    private static func row(for item: SourceProgress.Item) -> NoteRow {
        NoteRow(
            id: .live(item.summary.id), summary: item.summary, badge: NoteBadge(state: item.summary.state),
            overlays: item.overlays, isReadOnly: false)
    }

    // MARK: Fetching

    private struct Fill: Sendable {
        var pluginID: PluginID
        var fetched: [NoteSummary] = []
        var next: NoteCursor?
        var exhausted = false
        var total: Int?
        var failure: UnavailableSource.Reason?
    }

    private func fill(
        _ set: NoteSourceSet, progress: [PluginID: SourceProgress], query: NormalizedQuery?, size: Int
    ) async -> [Fill] {
        let budget = budget
        let clock = clock
        let logger = logger
        return await withTaskGroup(of: Fill?.self) { group in
            for id in set.order {
                guard let source = set.accepted[id] else { continue }
                let state = progress[id] ?? SourceProgress()
                if state.exhausted || state.buffer.count >= size { continue }
                group.addTask {
                    await Self.fetch(
                        source, state: state, query: query, size: size, budget: budget, clock: clock, logger: logger)
                }
            }
            var all: [Fill] = []
            for await fill in group { if let fill { all.append(fill) } }
            return all
        }
    }

    /// Pages through one source until its buffer holds `size` items, or it ends or does not answer.
    private static func fetch(
        _ source: any NoteSource, state: SourceProgress, query: NormalizedQuery?, size: Int, budget: Duration,
        clock: any Clock<Duration>, logger: Logger
    ) async -> Fill {
        var fill = Fill(pluginID: source.pluginID, next: state.next, exhausted: state.exhausted)
        var seen = Set(state.buffer.map(\.summary.id))
        var held = state.buffer.count
        var attempts = 0
        while held < size, !fill.exhausted, attempts < 4 {
            attempts += 1
            let cursor = fill.next
            let outcome = await SourceFanOut.call(budget: budget, clock: clock) {
                try await source.list(matching: query, after: cursor, limit: size)
            }
            switch outcome {
            case .value(let page):
                var dropped = 0
                for item in page.items {
                    guard item.id.pluginID == source.pluginID, seen.insert(item.id).inserted else {
                        dropped += 1
                        continue
                    }
                    fill.fetched.append(item)
                    held += 1
                }
                if dropped > 0 {
                    logger.error(
                        "note source \(source.pluginID.rawValue, privacy: .public): dropped \(dropped) items (foreign or repeated key)"
                    )
                }
                fill.total = page.total
                fill.next = page.next
                fill.exhausted = page.next == nil
            case .timedOut:
                fill.failure = .timedOut
                return fill
            case .failed:
                fill.failure = .failed
                return fill
            case .cancelled:
                return fill
            }
        }
        return fill
    }

    // MARK: Overlays

    /// Attaches the live overlays to freshly listed items. An overlay written against another start time than
    /// the source now reports is detached (through the detacher) before the item can be shown, and is not merged.
    private func resolve(_ fetched: [NoteSummary]) async -> (items: [SourceProgress.Item], overlaysAvailable: Bool) {
        let keys = fetched.map(\.id)
        let records: [OverlayRecord]
        do {
            records = try await overlays.overlays(for: keys)
        } catch {
            logger.error(
                "overlay index unreadable while listing: \(String(describing: type(of: error)), privacy: .public)")
            return (fetched.map { SourceProgress.Item(summary: $0, overlays: []) }, false)
        }
        var byKey: [NoteKey: [OverlayRecord]] = [:]
        for record in records { byKey[record.key, default: []].append(record) }
        var items: [SourceProgress.Item] = []
        for summary in fetched {
            let found = (byKey[summary.id] ?? []).sorted { $0.layer < $1.layer }
            let started = NoteTime.milliseconds(summary.startedAt)
            if found.contains(where: { $0.startedAtMs.map { $0 != started } ?? false }) {
                do {
                    try await detacher.detach(summary.id, reason: .startedAtChanged(sourceStartedAtMs: started))
                } catch {
                    logger.error("detach failed: \(String(describing: type(of: error)), privacy: .public)")
                    for record in found { detachedInMemory[record.docID] = record }
                }
                items.append(SourceProgress.Item(summary: summary, overlays: []))
            } else {
                items.append(SourceProgress.Item(summary: summary, overlays: found))
            }
        }
        return (items, true)
    }

    private func localRows(excludingPlugins live: Set<PluginID>) async -> (rows: [NoteRow], available: Bool) {
        var rows: [NoteRow] = []
        var available = true
        do {
            for record in try await overlays.manualNotes() {
                let summary = NoteSummary(
                    id: record.key, kind: .manual, title: record.title, startedAt: record.createdAt)
                rows.append(
                    NoteRow(id: .live(record.key), summary: summary, badge: nil, overlays: [record], isReadOnly: false))
            }
            var detached = try await overlays.detachedOverlays()
            let stored = Set(detached.map(\.docID))
            detached += detachedInMemory.values.filter { !stored.contains($0.docID) }.sorted { $0.docID < $1.docID }
            rows.append(contentsOf: Self.detachedRows(detached))
            rows.append(contentsOf: Self.offRows(try await overlays.keptOverlays(excludingPlugins: live)))
        } catch {
            logger.error(
                "overlay index unreadable while listing: \(String(describing: type(of: error)), privacy: .public)")
            available = false
        }
        return (rows, available)
    }

    /// One row per original recording, with every overlaid layer of it.
    private static func detachedRows(_ records: [OverlayRecord]) -> [NoteRow] {
        struct Origin: Hashable {
            var key: NoteKey
            var started: Int64
        }
        var groups: [Origin: [OverlayRecord]] = [:]
        for record in records {
            let started = record.startedAtMs ?? NoteTime.milliseconds(record.createdAt)
            groups[Origin(key: record.key, started: started), default: []].append(record)
        }
        return groups.compactMap { origin, group in
            guard let first = group.first else { return nil }
            let started = origin.started
            return NoteRow(
                id: .detached(origin.key, startedAtMs: started),
                summary: NoteSummary(
                    id: first.key, kind: first.kind, title: group.compactMap(\.title).first,
                    startedAt: NoteTime.date(milliseconds: started)),
                badge: .recordingRemoved, overlays: group.sorted { $0.layer < $1.layer }, isReadOnly: false)
        }
    }

    /// Kept overlays of a source that is off: read-only, never merged into a source row.
    private static func offRows(_ records: [OverlayRecord]) -> [NoteRow] {
        var groups: [NoteKey: [OverlayRecord]] = [:]
        for record in records { groups[record.key, default: []].append(record) }
        return groups.compactMap { key, group in
            guard let first = group.first else { return nil }
            let started = first.startedAtMs.map(NoteTime.date(milliseconds:)) ?? first.createdAt
            return NoteRow(
                id: .live(key),
                summary: NoteSummary(
                    id: key, kind: first.kind, title: group.compactMap(\.title).first, startedAt: started),
                badge: .sourceOff(first.sourcePluginID), overlays: group.sorted { $0.layer < $1.layer },
                isReadOnly: true)
        }
    }

    // MARK: Sweep

    /// The detach sweep's decision half: asks every OPEN source, in one batch per source, which of the keys
    /// that have an overlay still exist, and detaches the ones it omits. A source that is not active, was
    /// dropped, or throws detaches nothing; absence from a paged listing is never used. Returns the keys it
    /// detached.
    @discardableResult
    func sweep() async -> [NoteKey] {
        await ensureSources()
        let keys: [NoteKey]
        do {
            keys = try await overlays.liveOverlayKeys()
        } catch {
            logger.error(
                "overlay index unreadable in the sweep: \(String(describing: type(of: error)), privacy: .public)")
            return []
        }
        var byPlugin: [PluginID: [NoteKey]] = [:]
        for key in keys { byPlugin[key.pluginID, default: []].append(key) }
        var detached: [NoteKey] = []
        for (plugin, pluginKeys) in byPlugin.sorted(by: { $0.key < $1.key }) {
            guard let source = sources.accepted[plugin] else { continue }
            var existing = Set<NoteKey>()
            var answered = true
            for start in stride(from: 0, to: pluginKeys.count, by: 400) {
                let batch = Array(pluginKeys[start..<min(start + 400, pluginKeys.count)])
                let outcome = await SourceFanOut.call(budget: budget, clock: clock) { try await source.exists(batch) }
                guard case .value(let found) = outcome else {
                    answered = false
                    break
                }
                existing.formUnion(found)
            }
            guard answered else { continue }
            for key in pluginKeys where !existing.contains(key) {
                do {
                    try await detacher.detach(key, reason: .sourceGone)
                    detached.append(key)
                } catch {
                    logger.error("detach failed: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
        }
        return detached
    }
}

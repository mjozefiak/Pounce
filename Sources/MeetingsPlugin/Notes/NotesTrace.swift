import Foundation
import Synchronization

/// Receives the events of the notes trace (`NotesPipeline(trace:)`). There is none in the product.
typealias NotesTraceSink = @Sendable (NotesTraceEvent) -> Void

/// A record of what every stage of the notes did with the chunks and the points (MAP, the point guard, the
/// deduplication, REDUCE, the structure guard and the composer), to measure where a point is lost. It is off
/// unless a sink is given to `NotesPipeline`, and it never changes the result: the same calls run with and
/// without it. Nothing of it is logged or stored; it only goes to the sink.
///
/// Privacy: an event holds only what the code assigns or counts: chunk ids (`c1`, `c1.2`), point ids (`p12`,
/// assigned by the code, and only of points the code made), kinds, counts, utterance times in milliseconds,
/// token estimates and limits, flags and enum reasons. Never transcript text, a quote, a point's text, a
/// person, a due date, a speaker, the summary or the notes, and never an id the model wrote that is not one of
/// the points (those are only counted).
enum NotesTrace {
    /// Bumped when an event or a field changes meaning or goes away (adding one does not). 2: the verified
    /// summary points are shown as key points (`Section.keyPoints`, `Route.listedByCode`), so their fates and
    /// `NotesTraceReduce.nearDuplicatesSkipped` mean something else than in 1, and `NotesTraceReduce.keyPoints`
    /// is new. 3: a summary point whose text drifts from its quote is repaired (`NotesGuard.RepairReason
    /// .driftedFromQuote`), so `NotesTraceVerification.repaired` counts more than in 2, and
    /// `NotesTraceVerification.repairReasons` is new.
    static let schemaVersion = 3

    /// The points of `verified` that the deduplication took out, in their order.
    static func removedIDs(from verified: [NotesPoint], kept: [NotesPoint]) -> [String] {
        let keptIDs = Set(kept.map(\.id))
        return verified.map(\.id).filter { !keptIDs.contains($0) }
    }

    /// Where every verified point (after deduplication) ended: shown, or left out for a reason.
    struct Balance: Equatable, Sendable {
        /// The points kept by the deduplication (`NotesTraceEvent.deduplicated`).
        var verified = 0
        var rendered = 0
        /// Left out with a reason that the code gives (everything but `unexplained`).
        var notRendered = 0
        var unexplained = 0
        /// Verified points without a `point` event.
        var missingIDs: [String] = []
        /// `point` events of an id that is not a verified point, or a second one for the same id.
        var unexpectedIDs: [String] = []

        /// Every verified point is accounted for exactly once, each with an explicit fate.
        var isBalanced: Bool {
            unexplained == 0 && missingIDs.isEmpty && unexpectedIDs.isEmpty && verified == rendered + notRendered
        }
    }

    static func balance(of events: [NotesTraceEvent]) -> Balance {
        var balance = Balance()
        var verified: [String] = []
        var seen = Set<String>()
        for event in events {
            switch event {
            case .deduplicated(_, let kept):
                verified = kept
                balance.verified = kept.count
            case .point(let point):
                guard seen.insert(point.id).inserted else {
                    balance.unexpectedIDs.append(point.id)
                    continue
                }
                switch point.fate {
                case .rendered: balance.rendered += 1
                case .notRendered(.unexplained): balance.unexplained += 1
                case .notRendered: balance.notRendered += 1
                }
            default: break
            }
        }
        let verifiedSet = Set(verified)
        balance.missingIDs = verified.filter { !seen.contains($0) }
        balance.unexpectedIDs += seen.filter { !verifiedSet.contains($0) }.sorted()
        return balance
    }
}

/// One step of the notes, in the order the pipeline takes them. A run that throws (cancelled, or the model
/// could not be had) ends without `finished`.
enum NotesTraceEvent: Equatable, Sendable, Codable {
    case started(schemaVersion: Int, promptVersion: Int, utterances: Int, chunks: Int)
    /// One MAP request of a chunk or of a half of one (a split chunk is followed by its halves).
    case mapChunk(NotesTraceChunk)
    /// After `NotesGuard.verifyPoints`.
    case verified(NotesTraceVerification)
    /// After `NotesPipeline.deduplicated`: the ids it took out, and the ids that go on, in time order.
    case deduplicated(removedIDs: [String], keptIDs: [String])
    /// One REDUCE request (sections) or summary merge request.
    case reduceRequest(NotesTraceReduceRequest)
    /// The whole of REDUCE and of `NotesGuard.verifyReduce`.
    case reduce(NotesTraceReduce)
    case summary(NotesTraceSummary)
    /// The fate of one verified point, in time order.
    case point(NotesTracePoint)
    case finished(status: NotesResult.Status, verified: Int, rendered: Int, notRendered: Int)
}

/// Points by kind.
struct NotesTraceKinds: Equatable, Sendable, Codable {
    var summary = 0
    var decision = 0
    var task = 0
    var question = 0

    init() {}

    init(_ points: [NotesPoint]) {
        for point in points {
            switch point.kind {
            case .summary: summary += 1
            case .decision: decision += 1
            case .task: task += 1
            case .question: question += 1
            }
        }
    }

    var total: Int { summary + decision + task + question }
}

/// What one completion (a request with its retry rules) went through.
struct NotesTraceAttempts: Equatable, Sendable, Codable {
    /// Generation requests sent (one retry at most; a takeover by dictation repeats the request inside one).
    var requests = 0
    /// Answers cut off by the token limit (never used).
    var truncated = 0
    /// Answers that did not parse.
    var malformed = 0
    var timedOut = 0
    /// Other model errors.
    var errors = 0
    /// The prompt did not fit the context (before a request, or reported by the model).
    var promptTooLong = false
    /// The estimate of the first prompt (`NotesPipeline.promptTokens`).
    var promptTokens = 0
    /// The configured answer limit, and the limit of the last request sent (0 when none was).
    var firstMaxTokens = 0
    var lastMaxTokens = 0

    var retried: Bool { requests > 1 }
}

struct NotesTraceChunk: Equatable, Sendable, Codable {
    enum Outcome: String, Sendable, Codable {
        /// The answer gave points (maybe none).
        case points
        /// The chunk could not be processed; it is in `NotesResult.failedChunks`.
        case failed
        /// The prompt did not fit; the two halves follow as their own events.
        case split
    }

    var chunkID: String
    /// The times of the first and the last utterance of the chunk (`TranscriptChunk.startMs` / `endMs`).
    var startMs: Int
    var endMs: Int
    var utterances: Int
    /// `TranscriptChunk.estimatedTokens`, the transcript lines alone.
    var estimatedTokens: Int
    var attempts: NotesTraceAttempts
    var outcome: Outcome
    var proposed: NotesTraceKinds
    /// The chunk's proposed points get the ids `p<firstPointNumber>`, `p<firstPointNumber + 1>`, … in order.
    var firstPointNumber: Int

    init(
        chunk: TranscriptChunk, attempts: NotesTraceAttempts, outcome: Outcome, proposed: [NotesPoint],
        firstPointNumber: Int
    ) {
        chunkID = chunk.id
        startMs = chunk.startMs
        endMs = chunk.endMs
        utterances = chunk.utterances.count
        estimatedTokens = chunk.estimatedTokens
        self.attempts = attempts
        self.outcome = outcome
        self.proposed = NotesTraceKinds(proposed)
        self.firstPointNumber = firstPointNumber
    }
}

struct NotesTraceVerification: Equatable, Sendable, Codable {
    var proposed: Int
    var verified: NotesTraceKinds
    var dropped: Int
    var reasons: [NotesGuard.DropReason: Int]
    var repaired: Int
    var downgraded: Int
    /// `repaired` by the reason of each repair (schema 3; empty when decoded from an older trace).
    var repairReasons: [NotesGuard.RepairReason: Int]
    /// Tasks whose person is the speaker, given by the guard (a count; empty trace field reads as 0).
    var ownerFromSpeaker = 0
    /// What the semantic verifier did (counts only); nil when it did not run and in older traces. `repaired`
    /// and `repairReasons` above are the counts after it.
    var verifier: NotesTraceVerifier?

    private enum CodingKeys: String, CodingKey {
        case proposed, verified, dropped, reasons, repaired, downgraded, repairReasons, ownerFromSpeaker, verifier
    }

    /// `reasons` and `repairReasons` are written as objects keyed by the reason's raw value (a dictionary keyed
    /// by an enum would become an array of alternating keys and values).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proposed = try container.decode(Int.self, forKey: .proposed)
        verified = try container.decode(NotesTraceKinds.self, forKey: .verified)
        dropped = try container.decode(Int.self, forKey: .dropped)
        reasons = try Self.decodeCounts(
            NotesGuard.DropReason.self, forKey: .reasons, in: container, unknown: "Unknown drop reason")
        repaired = try container.decode(Int.self, forKey: .repaired)
        downgraded = try container.decode(Int.self, forKey: .downgraded)
        repairReasons =
            container.contains(.repairReasons)
            ? try Self.decodeCounts(
                NotesGuard.RepairReason.self, forKey: .repairReasons, in: container, unknown: "Unknown repair reason")
            : [:]
        ownerFromSpeaker = try container.decodeIfPresent(Int.self, forKey: .ownerFromSpeaker) ?? 0
        verifier = try container.decodeIfPresent(NotesTraceVerifier.self, forKey: .verifier)
    }

    private static func decodeCounts<Reason: RawRepresentable & Hashable>(
        _ type: Reason.Type, forKey key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>,
        unknown: String
    ) throws -> [Reason: Int] where Reason.RawValue == String {
        var decoded: [Reason: Int] = [:]
        for (raw, count) in try container.decode([String: Int].self, forKey: key) {
            guard let reason = Reason(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: unknown)
            }
            decoded[reason] = count
        }
        return decoded
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(proposed, forKey: .proposed)
        try container.encode(verified, forKey: .verified)
        try container.encode(dropped, forKey: .dropped)
        try container.encode(
            Dictionary(uniqueKeysWithValues: reasons.map { ($0.key.rawValue, $0.value) }), forKey: .reasons)
        try container.encode(repaired, forKey: .repaired)
        try container.encode(downgraded, forKey: .downgraded)
        try container.encode(
            Dictionary(uniqueKeysWithValues: repairReasons.map { ($0.key.rawValue, $0.value) }),
            forKey: .repairReasons)
        try container.encode(ownerFromSpeaker, forKey: .ownerFromSpeaker)
        try container.encodeIfPresent(verifier, forKey: .verifier)
    }

    init(proposed: Int, verdict: NotesGuard.PointVerdict, verifier: NotesTraceVerifier? = nil) {
        self.verifier = verifier
        self.proposed = proposed
        verified = NotesTraceKinds(verdict.verified)
        dropped = verdict.dropped
        reasons = verdict.reasons
        repaired = verdict.repaired
        downgraded = verdict.downgraded
        repairReasons = verdict.repairReasons
        ownerFromSpeaker = verdict.ownerFromSpeaker
    }
}

/// The semantic verifier of one run: counts, flags and the prompt version, never text.
struct NotesTraceVerifier: Equatable, Sendable, Codable {
    var promptVersion: Int
    /// Points that could be asked: kept by the guard, or repaired only for `unsupportedDetail` or
    /// `driftedFromQuote` (after deduplication).
    var eligible = 0
    /// Points that got an answer of any kind before the time limit (`supported + weaker + unsupported + failed`).
    var asked = 0
    var supported = 0
    var weaker = 0
    var unsupported = 0
    /// Answers that were malformed, cut off, failed or cancelled: the point stays as the guard left it.
    var failed = 0
    /// Eligible points left without an answer because the time ran out (or the run was stopped).
    var notAsked = 0
    /// Repaired points that got the model's text back.
    var restoredModelText = 0
    /// Kept points replaced by their quote (`NotesGuard.RepairReason.verifierRejected`).
    var rejectedKept = 0
    var budgetExceeded = false
    /// Wall-clock time of the verifier stage.
    var elapsedMs = 0
}

struct NotesTraceReduceRequest: Equatable, Sendable, Codable {
    enum Stage: String, Sendable, Codable { case sections, summaryMerge }
    enum Outcome: String, Sendable, Codable {
        case value
        /// The prompt did not fit; the points went on in two batches.
        case split
        /// The request failed; the batch's points went into the sections in code order (`reduceFailed`).
        case codeOrder
        /// A summary merge failed; the paragraph is composed from the points (`reduceFailed`).
        case failed
    }

    var stage: Stage
    /// Points (sections) or partial summaries (merge) in the request.
    var inputs: Int
    /// The points of a sections request.
    var pointIDs: [String]
    var attempts: NotesTraceAttempts
    var outcome: Outcome
}

struct NotesTraceReduce: Equatable, Sendable, Codable {
    /// Batches of the first level (1 when the points fit one request).
    var batches = 0
    var sectionRequests = 0
    var summaryMergeRequests = 0
    /// Summary merges given up without a request (two partial summaries did not fit together).
    var summaryMergesGivenUp = 0
    var codeOrderBatches = 0
    /// Generation requests sent by REDUCE and the merges, and the answers of them cut off by the limit.
    var generationRequests = 0
    var truncatedAnswers = 0
    var reduceFailed = false
    /// What `NotesGuard.verifyReduce` returned.
    var decisions = 0
    var tasks = 0
    var questions = 0
    var rejectedIDs = 0
    /// `rejectedIDs`, split: ids that are no verified point, and verified points listed in another kind's section.
    var rejectedUnknown = 0
    var rejectedWrongSection = 0
    /// An id listed twice in its own section (kept once, not rejected).
    var repeatedIDs = 0
    var backfilled = 0
    /// Points left out and not added back because a near-duplicate is in their section (the key points
    /// included).
    var nearDuplicatesSkipped = 0
    /// The summary points shown as key points.
    var keyPoints = 0
    var summaryReplaced = false
}

struct NotesTraceSummary: Equatable, Sendable, Codable {
    var origin: NotesGuard.ReduceAudit.SummaryOrigin
    /// The verdict has a paragraph, and the composer shows it.
    var present: Bool
    var shown: Bool
    /// The points whose first sentence makes the composed paragraph (empty for the model's paragraph).
    var sourceIDs: [String]
    var sourceStartMs: Int?
    var sourceEndMs: Int?
    /// Why the model's paragraph was refused (a rule, never text); nil for older traces and for no refusal.
    var refusal: NotesGuard.SummaryRefusal?
}

struct NotesTracePoint: Equatable, Sendable, Codable {
    enum Section: String, Sendable, Codable {
        case summary, decisions, tasks, questions
        /// The key points: the verified summary points the code lists (`NotesGuard.ReduceVerdict.keyPoints`).
        case keyPoints

        init?(kind: NotesPointKind) {
            switch kind {
            case .summary: return nil
            case .decision: self = .decisions
            case .task: self = .tasks
            case .question: self = .questions
            }
        }

        init(listOf kind: NotesPointKind) {
            self = Section(kind: kind) ?? .summary
        }
    }

    /// How a shown point got into its section.
    enum Route: String, Sendable, Codable {
        /// REDUCE listed it in its section.
        case reduce
        /// REDUCE failed for its batch and the code listed every point of the batch.
        case codeOrder
        /// REDUCE left it out (or put it in another section) and the guard added it back.
        case backfilled
        /// A summary point whose first sentence is in the paragraph composed by the code.
        case composedSummary
        /// A summary point the code lists among the key points (REDUCE does not choose them).
        case listedByCode
    }

    enum Loss: Equatable, Sendable, Codable {
        /// Schema 1 only (summary points had no section then): a summary point and the paragraph shown is the
        /// model's. Not produced since schema 2, where the point is a key point.
        case summaryKindModelParagraph
        /// Schema 1 only: a summary point that is not among the first four sources of the composed paragraph.
        /// Not produced since schema 2, where the point is a key point.
        case summaryKindNotInComposedParagraph
        /// A source of the composed paragraph, but the composer shows no paragraph.
        case summaryNotShown
        /// REDUCE left it out (or put it in another section) and the guard did not add it back because this
        /// point, of the same kind, is in its section and near-duplicates it (`NotesGuard.nearDuplicate`).
        case nearDuplicateInSection(of: String)
        /// The trace cannot tell from the guard's audit; the balance counts it apart.
        case unexplained
    }

    enum Fate: Equatable, Sendable, Codable {
        case rendered(Section, via: Route)
        case notRendered(Loss)
    }

    var id: String
    /// The kind after the guard (a downgraded decision or task is a question here).
    var kind: NotesPointKind
    var proposedKind: NotesPointKind?
    /// The time of the quoted utterance.
    var timeMs: Int
    /// The sections REDUCE listed it in that are not its kind's (each is one of `rejectedWrongSection`).
    var misfiledInto: [Section]
    var fate: Fate
}

/// Builds the events of one run and keeps what later events need (the codeOrder batches, the fates).
final class NotesTraceRecorder: Sendable {
    private struct State {
        var reduce = NotesTraceReduce()
        var codeOrderIDs = Set<String>()
        var rendered = 0
        var notRendered = 0
    }

    private let sink: NotesTraceSink
    private let state = Mutex(State())

    init(sink: @escaping NotesTraceSink) {
        self.sink = sink
    }

    func emit(_ event: NotesTraceEvent) {
        sink(event)
    }

    func reduceBatches(_ count: Int) {
        state.withLock { $0.reduce.batches = count }
    }

    func reduceRequest(
        stage: NotesTraceReduceRequest.Stage, inputs: Int, pointIDs: [String], attempts: NotesTraceAttempts,
        outcome: NotesTraceReduceRequest.Outcome
    ) {
        state.withLock { state in
            switch stage {
            case .sections: state.reduce.sectionRequests += 1
            case .summaryMerge: state.reduce.summaryMergeRequests += 1
            }
            state.reduce.generationRequests += attempts.requests
            state.reduce.truncatedAnswers += attempts.truncated
            if outcome == .codeOrder {
                state.reduce.codeOrderBatches += 1
                state.codeOrderIDs.formUnion(pointIDs)
            }
        }
        emit(
            .reduceRequest(
                NotesTraceReduceRequest(
                    stage: stage, inputs: inputs, pointIDs: pointIDs, attempts: attempts, outcome: outcome)))
    }

    func summaryMergeGivenUp() {
        state.withLock { $0.reduce.summaryMergesGivenUp += 1 }
    }

    /// The `reduce`, `summary` and `point` events, once the structure is verified.
    func reduced(
        points: [NotesPoint], proposed: [NotesPoint], verdict: NotesGuard.ReduceVerdict,
        audit: NotesGuard.ReduceAudit, reduceFailed: Bool, summaryShown: Bool
    ) {
        let (reduce, codeOrderIDs) = state.withLock { state -> (NotesTraceReduce, Set<String>) in
            state.reduce.reduceFailed = reduceFailed
            state.reduce.decisions = verdict.decisions.count
            state.reduce.tasks = verdict.tasks.count
            state.reduce.questions = verdict.questions.count
            state.reduce.rejectedIDs = verdict.rejectedIDs
            state.reduce.rejectedUnknown = audit.unknownIDs
            state.reduce.rejectedWrongSection = audit.misfiled.values.reduce(0) { $0 + $1.count }
            state.reduce.repeatedIDs = audit.repeatedIDs
            state.reduce.backfilled = verdict.backfilled
            state.reduce.nearDuplicatesSkipped = audit.nearDuplicateOf.count
            state.reduce.keyPoints = verdict.keyPoints.count
            state.reduce.summaryReplaced = verdict.summaryReplaced
            return (state.reduce, state.codeOrderIDs)
        }
        emit(.reduce(reduce))

        let times = Dictionary(points.map { ($0.id, $0.timeMs) }, uniquingKeysWith: { first, _ in first })
        let sourceTimes = audit.summarySources.compactMap { times[$0] }
        emit(
            .summary(
                NotesTraceSummary(
                    origin: audit.summaryOrigin, present: verdict.summary != nil, shown: summaryShown,
                    sourceIDs: audit.summarySources, sourceStartMs: sourceTimes.min(),
                    sourceEndMs: sourceTimes.max(), refusal: audit.summaryRefusal)))

        let proposedKinds = Dictionary(proposed.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        for point in points {
            let fate = Self.fate(
                of: point, verdict: verdict, audit: audit, codeOrderIDs: codeOrderIDs, summaryShown: summaryShown)
            state.withLock { state in
                if case .rendered = fate { state.rendered += 1 } else { state.notRendered += 1 }
            }
            emit(
                .point(
                    NotesTracePoint(
                        id: point.id, kind: point.kind, proposedKind: proposedKinds[point.id], timeMs: point.timeMs,
                        misfiledInto: (audit.misfiled[point.id] ?? []).map(NotesTracePoint.Section.init(listOf:)),
                        fate: fate)))
        }
    }

    func finish(_ result: NotesResult) {
        let (rendered, notRendered) = state.withLock { ($0.rendered, $0.notRendered) }
        emit(
            .finished(
                status: result.status, verified: result.verifiedPointCount, rendered: rendered,
                notRendered: notRendered))
    }

    /// Read from the verdict and the guard's audit: the composer shows every point of `keyPoints`, `decisions`,
    /// `tasks` and `questions` as a bullet and nothing else, and the paragraph when `NotesComposer.shownSummary`
    /// has one. A summary point both listed and in the composed paragraph counts as a key point (the bullet
    /// shows its whole text).
    static func fate(
        of point: NotesPoint, verdict: NotesGuard.ReduceVerdict, audit: NotesGuard.ReduceAudit,
        codeOrderIDs: Set<String>, summaryShown: Bool
    ) -> NotesTracePoint.Fate {
        guard let section = NotesTracePoint.Section(kind: point.kind) else {
            if verdict.keyPoints.contains(where: { $0.id == point.id }) {
                return .rendered(.keyPoints, via: .listedByCode)
            }
            if audit.summarySources.contains(point.id) {
                return summaryShown ? .rendered(.summary, via: .composedSummary) : .notRendered(.summaryNotShown)
            }
            if let other = audit.nearDuplicateOf[point.id] { return .notRendered(.nearDuplicateInSection(of: other)) }
            return .notRendered(.unexplained)
        }
        let list: [NotesPoint]
        switch section {
        case .decisions: list = verdict.decisions
        case .tasks: list = verdict.tasks
        case .questions, .summary, .keyPoints: list = verdict.questions
        }
        if list.contains(where: { $0.id == point.id }) {
            if audit.backfilled.contains(point.id) { return .rendered(section, via: .backfilled) }
            return .rendered(section, via: codeOrderIDs.contains(point.id) ? .codeOrder : .reduce)
        }
        if let other = audit.nearDuplicateOf[point.id] { return .notRendered(.nearDuplicateInSection(of: other)) }
        return .notRendered(.unexplained)
    }
}

// The enums that live in other files get their `Codable` here (their raw values are the coded form).
extension NotesPointKind: Codable {}
extension NotesResult.Status: Codable {}
extension NotesGuard.DropReason: Codable {}
extension NotesGuard.RepairReason: Codable {}
extension NotesGuard.ReduceAudit.SummaryOrigin: Codable {}

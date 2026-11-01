import PounceKit

/// Shared, source-agnostic search logic without I/O: text normalisation, fuzzy matching and ranking.
///
/// Phase 0 only creates the target so the dependency graph is in place; `TextNormalizer`,
/// `FuzzyMatcher` and `Ranker` arrive in Phase 1 (spec steps 1.1 and 1.6).
public enum PounceCore {
    /// The tiers every source ranks by, best first.
    public static let tierOrder: [MatchTier] = MatchTier.allCases.sorted()
}

// IndexedScopedRunner.swift
// RunnerBarCore

// MARK: - IndexedScopedRunner

/// Carries a scope-fetched `Runner` alongside its source-scope string.
/// Used internally by `fetchAndEnrichRunners` to pass data through two
/// concurrent `withTaskGroup` phases without a 3-member tuple
/// (which would trigger the `large_tuple` SwiftLint rule).
///
/// ⚠️ The ordering of entries in the `indexed` array after Phase 1 is
/// non-deterministic: `withTaskGroup` tasks complete in arrival order.
/// This matches the previous `RunnerStore` behaviour; views sort
/// runners independently for display.
struct IndexedScopedRunner {
    /// The GitHub scope URL string (repo or org) this runner belongs to.
    var scope: String
    /// The enriched `Runner` value. Mutated in-place during Phase 2 to add metrics.
    var runner: Runner
}

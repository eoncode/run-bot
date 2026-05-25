// ScopeEntry.swift
// RunnerBar
import Foundation

// MARK: - ScopeEntry

/// A single watched GitHub scope (repo or org) with an enable/disable flag.
///
/// `scope` is either `"owner/repo"` (repository) or `"myorg"` (organisation).
/// `isEnabled` controls whether `RunnerStore` polls this scope; disabled scopes
/// are retained in the list but silently skipped during fetch.
struct ScopeEntry: Identifiable, Codable, Equatable {
    /// Stable identifier used by `ScopeStore` to locate and mutate individual entries.
    let id: UUID
    /// The raw GitHub scope string, e.g. `"owner/repo"` or `"myorg"`.
    var scope: String
    /// Whether `RunnerStore` should actively poll this scope for runner status.
    var isEnabled: Bool

    /// Convenience init with a new random ID and enabled by default.
    init(scope: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.scope = scope
        self.isEnabled = isEnabled
    }
}

// ScopePreferencesStoreProtocol.swift
// RunnerBarCore
import Foundation

// MARK: - ScopePreferencesStoreProtocol

/// Abstracts per-scope preference reads, writes, and removal so views
/// and use-cases can be tested without hitting `UserDefaults` on disk.
@MainActor
public protocol ScopePreferencesStoreProtocol: AnyObject {

    /// Returns the full preferences snapshot for `scope`.
    /// Always returns a value — missing keys are represented as `nil` fields
    /// inside `ScopePreferences`, never as a missing record.
    func preferences(for scope: String) -> ScopePreferences

    /// Atomically persists all fields in `prefs` for `scope`.
    /// Replaces the previous per-field write pattern with a single call.
    func setPreferences(_ prefs: ScopePreferences, for scope: String)

    /// Human-readable display name for `scope`.
    /// Returns the stored alias if one exists, otherwise the raw scope string.
    /// Never returns `nil` — callers can use the result directly in UI without
    /// unwrapping.
    func displayName(for scope: String) -> String

    /// Removes all persisted preference keys for `scope`.
    /// Call when a scope is deleted so orphaned `UserDefaults` keys do not accumulate.
    func removePreferences(for scope: String)
}

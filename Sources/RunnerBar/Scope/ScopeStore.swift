// ScopeStore.swift
// RunnerBar
// swiftlint:disable orphaned_doc_comment
import Combine
import Foundation

// MARK: - ScopeStore

/// Persists the list of watched GitHub scopes as `[ScopeEntry]` in `UserDefaults`.
///
/// Migration: if the legacy `"scopes"` key (plain `[String]`) is present on first
/// launch it is converted to `[ScopeEntry]` (all enabled) and the old key is deleted.
///
/// Conforms to `ObservableObject` — SwiftUI views should use `@ObservedObject`.
/// Subscribe to `didMutate` to be notified after any structural change (add / remove).
final class ScopeStore: ObservableObject {
    /// Shared singleton — single source of truth for all scope operations.
    static let shared = ScopeStore()

    /// `UserDefaults` key used to persist the `[ScopeEntry]` JSON blob.
    private let entriesKey = "scopeEntries"
    /// Legacy `UserDefaults` key (`[String]`) migrated on first launch.
    private let legacyKey = "scopes"

    /// Emits after every structural mutation (add / remove). Callers subscribe and
    /// store the resulting `AnyCancellable`. Using a subject instead of a plain
    /// optional closure avoids any risk of a retain cycle at the call site.
    let didMutate = PassthroughSubject<Void, Never>()

    /// All scope entries, persisted as JSON in `UserDefaults`.
    /// Publishes `objectWillChange` before every write so observing views update.
    @Published private(set) var entries: [ScopeEntry] = [] {
        willSet { objectWillChange.send() }
    }

    /// Scopes that are currently enabled — used by `RunnerStore` for polling.
    var activeScopes: [String] { entries.filter(\.isEnabled).map(\.scope) }

    /// Legacy accessor: all scope strings regardless of enabled state.
    /// Kept for call-sites not yet migrated; prefer `activeScopes`.
    var scopes: [String] { entries.map(\.scope) }

    /// Initialises the store by loading persisted entries (or migrating the
    /// legacy `[String]` key if present).
    private init() {
        entries = loadEntries()
    }

    // MARK: - Persistence

    /// Loads `[ScopeEntry]` from `UserDefaults`, migrating the legacy
    /// `[String]` key when found. Returns an empty array on decode failure.
    private func loadEntries() -> [ScopeEntry] {
        // Migration: convert legacy [String] key i
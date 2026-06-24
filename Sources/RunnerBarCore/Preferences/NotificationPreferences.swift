// NotificationPreferences.swift
// RunnerBarCore
import Foundation
import Observation

// MARK: - NotificationPreferences

/// Persists notification preferences to UserDefaults.
///
/// ## Dependency injection (P7)
/// The `didSet` observers write to the injected `defaults` instance rather than
/// directly to `UserDefaults.standard`, matching the pattern in `AppPreferencesStore`
/// so that unit tests can supply an ephemeral suite without polluting the real
/// preferences database.
@MainActor
@Observable
public final class NotificationPreferences {
    /// Shared singleton — use this instead of calling init directly.
    public static let shared = NotificationPreferences()

    /// UserDefaults key constants.
    private enum Key {
        /// Key for the notify-on-success flag.
        static let notifyOnSuccess = "notifications.notifyOnSuccess"
        /// Key for the notify-on-failure flag.
        static let notifyOnFailure = "notifications.notifyOnFailure"
    }

    // MARK: - Backing store

    /// The `UserDefaults` instance used for all reads and writes.
    /// Injected at init; defaults to `.standard` in production.
    private let defaults: UserDefaults

    // MARK: - Preferences

    /// Whether the user wants a notification when a job succeeds.
    public var notifyOnSuccess: Bool {
        didSet { defaults.set(notifyOnSuccess, forKey: Key.notifyOnSuccess) }
    }

    /// Whether the user wants a notification when a job fails.
    public var notifyOnFailure: Bool {
        didSet { defaults.set(notifyOnFailure, forKey: Key.notifyOnFailure) }
    }

    // MARK: - Init

    /// Convenience initialiser for production use. Calls `init(store: .standard)`.
    private convenience init() {
        self.init(store: .standard)
    }

    /// Designated initialiser.
    ///
    /// - Parameter store: The `UserDefaults` suite to read from and write to.
    ///   Pass `.standard` in production (via the `shared` singleton) or an
    ///   ephemeral suite (`UserDefaults(suiteName:)`) in unit tests to avoid
    ///   polluting the real preferences database. (P7)
    public init(store: UserDefaults) {
        self.defaults = store
        NotificationPreferences.register(into: store)
        notifyOnSuccess = store.bool(forKey: Key.notifyOnSuccess)
        notifyOnFailure = store.bool(forKey: Key.notifyOnFailure)
    }

    // MARK: - Registration

    /// Registers factory defaults so that `bool(forKey:)` returns the intended
    /// value on first launch without requiring an `object(forKey:) == nil` guard.
    ///
    /// Call once at app startup (e.g. from `applicationDidFinishLaunching`) and
    /// again in unit tests before exercising notification logic.
    ///
    /// - Parameter store: The `UserDefaults` instance to register defaults into.
    ///   Pass `.standard` for production; pass a suite instance in tests.
    public static func register(into store: UserDefaults) {
        store.register(defaults: [
            Key.notifyOnSuccess: true,
            Key.notifyOnFailure: true,
        ])
    }
}

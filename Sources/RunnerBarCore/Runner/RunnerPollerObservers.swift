// RunnerPollerObservers.swift
// RunnerBarCore
//
// Step 10: Moved from RunnerBar app target to RunnerBarCore.
// Classes made `public` so RunnerPoller (in Core) can reference them.
import Foundation

// MARK: - PreferencesObserver

/// Drives a recursive `withObservationTracking` loop for `AppPreferencesStoreProtocol.pollingInterval`
/// entirely on the `@MainActor`. Because every method is `@MainActor`-isolated, the local
/// `func observe()` inside `start()` is implicitly `@MainActor` — no `@Sendable` annotation
/// is required and no value crosses an isolation boundary.
///
/// - Note: This class is `internal` (not `private`) intentionally. It was `private final class`
///   in `RunnerStore.swift` before being extracted to this file. Swift `private` is file-scoped,
///   so moving it to a separate file requires at least `internal` visibility for
///   `RunnerStore.swift` to reference it across the file boundary. It remains invisible
///   outside the `RunnerBar` module. Do not narrow back to `private` — that will break
///   the cross-file reference in `RunnerStore.swift`.
@MainActor
public final class PreferencesObserver {
    /// The continuation used to push new `pollingInterval` values into the `AsyncStream`.
    private let continuation: AsyncStream<Int>.Continuation
    /// The injected preferences store — avoids singleton access inside the observer.
    private let store: any AppPreferencesStoreProtocol

    /// Creates a new observer that writes changes into `continuation`.
    public init(continuation: AsyncStream<Int>.Continuation, store: any AppPreferencesStoreProtocol) {
        self.continuation = continuation
        self.store = store
    }

    /// Registers a single `withObservationTracking` pass and re-registers itself on change.
    func start() {
        func observe() {
            withObservationTracking {
                _ = store.pollingInterval
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.continuation.yield(self.store.pollingInterval)
                    self.start()
                }
            }
        }
        observe()
    }
}

// MARK: - ScopesObserver

/// Drives a recursive `withObservationTracking` loop for `ScopeStoreProtocol.activeScopes`
/// entirely on the `@MainActor`. Same isolation rationale as `PreferencesObserver`.
///
/// - Note: `internal` visibility is intentional — see `PreferencesObserver` doc-comment
///   for the full rationale. Do not narrow back to `private`.
@MainActor
public final class ScopesObserver {
    /// The continuation used to push new `activeScopes` values into the `AsyncStream`.
    private let continuation: AsyncStream<[String]>.Continuation
    /// The injected scope store — avoids singleton access inside the observer.
    private let store: any ScopeStoreProtocol

    /// Creates a new observer that writes changes into `continuation`.
    public init(continuation: AsyncStream<[String]>.Continuation, store: any ScopeStoreProtocol) {
        self.continuation = continuation
        self.store = store
    }

    /// Registers a single `withObservationTracking` pass and re-registers itself on change.
    func start() {
        func observe() {
            withObservationTracking {
                _ = store.activeScopes
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.continuation.yield(self.store.activeScopes)
                    self.start()
                }
            }
        }
        observe()
    }
}

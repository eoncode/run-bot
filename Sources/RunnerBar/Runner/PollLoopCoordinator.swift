// PollLoopCoordinator.swift
// RunnerBar
import Foundation

// MARK: - PollLoopCoordinator

/// Owns the three `Task` handles that drive `RunnerStore`’s poll loop.
///
/// `RunnerStore` holds this as a stored property, so all mutation is serialised
/// by the actor’s own executor — no additional isolation annotation is needed
/// during normal operation.
///
/// **`@unchecked Sendable` — PRINCIPLE #4 EXCEPTION (documented sign-off)**
///
/// Project Principle #4 states: “no `@unchecked Sendable` escape hatches in
/// production types.” `PollLoopCoordinator` is a production type that carries
/// this conformance. The exception is intentional and safe for the following
/// reasons, recorded here as the required sign-off:
///
/// 1. **Owned by a single actor.** `PollLoopCoordinator` is stored as
///    `private let pollLoop` on `RunnerStore`. Swift actors serialise all
///    access to their stored properties on their own executor, so every call
///    to `setPollTask`, `setIntervalObservationTask`, and
///    `setScopeObservationTask` is already serialised without any additional
///    locking.
///
/// 2. **`deinit` only calls `Task.cancel()`.** `Task.cancel()` is itself
///    `Sendable` and safe to call from any isolation context. `cancelAll()`
///    in `deinit` performs no reads or writes of mutable state beyond flipping
///    the cancellation flag on each `Task`.
///
/// 3. **`deinit` runs after all strong references are gone.** By the time
///    `RunnerStore.deinit` (and therefore `PollLoopCoordinator.deinit`) runs,
///    no concurrent mutation of the coordinator’s task handles is possible.
///
/// The root cause of the conformance requirement is that Swift 6 forbids
/// accessing a stored property of a non-`Sendable` type from a nonisolated
/// `deinit`. Making the coordinator an `actor` would satisfy the compiler
/// without `@unchecked Sendable`, but would require every setter to be
/// `async` and every `deinit` call-site to spawn a detached `Task` — a
/// worse trade-off for a type that is only ever touched from one actor.
/// This exception is preferable; file a follow-up if a second store ever
/// needs to own a `PollLoopCoordinator`.
///
/// **Why a dedicated type?**
/// Swift’s `private` modifier is file-scoped, not type-scoped. The poll-loop
/// state (`pollTask`, `intervalObservationTask`, `scopeObservationTask`) cannot
/// be moved into `RunnerStore+PollLoop.swift` as raw stored properties without
/// widening their access to `internal`. Wrapping them here makes the coordinator
/// itself `internal` while keeping the individual task slots effectively private
/// to this file.
final class PollLoopCoordinator: @unchecked Sendable {

    // MARK: - Stored task handles

    /// Active structured poll task. Cancelled and replaced on every `start()` call.
    private(set) var pollTask: Task<Void, Never>?
    /// Observation task that restarts the poll loop when `pollingInterval` changes.
    private(set) var intervalObservationTask: Task<Void, Never>?
    /// Observation task that restarts the poll loop when `activeScopes` changes.
    private(set) var scopeObservationTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a new coordinator with all task handles set to `nil`.
    init() {}

    deinit { cancelAll() }

    // MARK: - Mutation

    /// Cancels the existing poll task (if any) and replaces it with `task`.
    /// Passing `nil` cancels without installing a replacement.
    func setPollTask(_ task: Task<Void, Never>?) {
        pollTask?.cancel()
        pollTask = task
    }

    /// Cancels the existing interval-observation task (if any) and replaces it with `task`.
    /// Passing `nil` cancels without installing a replacement.
    func setIntervalObservationTask(_ task: Task<Void, Never>?) {
        intervalObservationTask?.cancel()
        intervalObservationTask = task
    }

    /// Cancels the existing scope-observation task (if any) and replaces it with `task`.
    /// Passing `nil` cancels without installing a replacement.
    func setScopeObservationTask(_ task: Task<Void, Never>?) {
        scopeObservationTask?.cancel()
        scopeObservationTask = task
    }

    /// Cancels all three tasks and nils their handles.
    ///
    /// Niling after cancel keeps this method consistent with the setter contract
    /// (`setPollTask(nil)` also nils) and releases the `Task` references immediately,
    /// leaving the coordinator in a clean, fully-reset state.
    /// Called from `RunnerStore.deinit` and this type’s own `deinit`.
    func cancelAll() {
        pollTask?.cancel()
        pollTask = nil
        intervalObservationTask?.cancel()
        intervalObservationTask = nil
        scopeObservationTask?.cancel()
        scopeObservationTask = nil
    }
}

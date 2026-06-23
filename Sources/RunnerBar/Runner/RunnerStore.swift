// RunnerStore.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - Protocols

/// Protocol that abstracts the polling-interval preference, allowing test doubles
/// to be injected into `RunnerStore` without going through the live singleton.
///
/// `Sendable` conformance is required so the existential can be captured by the
/// actor and read inside `await MainActor.run { }` closures without triggering
/// Swift 6's non-Sendable-type-exits-actor-isolated-context error.
///
/// - Note: Test doubles that implement this protocol with mutable state (e.g.
///   `var pollingInterval: Int`) must declare `@unchecked Sendable` to satisfy
///   the compiler under `-strict-concurrency=complete`. The `@MainActor`
///   isolation on the protocol guarantees all access happens on the main actor,
///   making `@unchecked` safe in practice for simple fake classes.
///
/// - Important: Conforming types **must** be `@Observable`. `RunnerStore` wires
///   change notifications via `withObservationTracking`, which only fires its
///   `onChange` callback for properties accessed on concrete `@Observable` types.
///   A plain class conformance compiles correctly but the `onChange` closure will
///   never fire, so the poll loop will silently not restart when `pollingInterval`
///   changes. Annotate all test doubles with `@Observable` to preserve production
///   behaviour.
@MainActor
protocol AppPreferencesStoreProtocol: AnyObject, Sendable {
    /// The current polling interval, in seconds, as configured by the user.
    var pollingInterval: Int { get }
}

/// Conforms `AppPreferencesStore` to `AppPreferencesStoreProtocol` so the live
/// singleton can be injected at the production call site without any wrapper.
extension AppPreferencesStore: AppPreferencesStoreProtocol {}

/// Protocol that abstracts the active-scopes store, allowing test doubles
/// to be injected into `RunnerStore` without going through the live singleton.
///
/// `Sendable` conformance is required so the existential can be captured by the
/// actor and read inside `await MainActor.run { }` closures without triggering
/// Swift 6's non-Sendable-type-exits-actor-isolated-context error.
///
/// - Note: Test doubles that implement this protocol with mutable state (e.g.
///   `var activeScopes: [String]`) must declare `@unchecked Sendable` to satisfy
///   the compiler under `-strict-concurrency=complete`. The `@MainActor`
///   isolation on the protocol guarantees all access happens on the main actor,
///   making `@unchecked` safe in practice for simple fake classes.
///
/// - Important: Conforming types **must** be `@Observable`. `RunnerStore` wires
///   change notifications via `withObservationTracking`, which only fires its
///   `onChange` callback for properties accessed on concrete `@Observable` types.
///   A plain class conformance compiles correctly but the `onChange` closure will
///   never fire, so the poll loop will silently not restart when `activeScopes`
///   changes. Annotate all test doubles with `@Observable` to preserve production
///   behaviour.
@MainActor
protocol ScopeStoreProtocol: AnyObject, Sendable {
    /// The list of scope identifiers (org or repo slugs) currently active.
    var activeScopes: [String] { get }
}

/// Conforms `ScopeStore` to `ScopeStoreProtocol` so the live singleton can be
/// injected at the production call site without any wrapper.
extension ScopeStore: ScopeStoreProtocol {}

// MARK: - RunnerStore

/// Swift 6 actor that owns the GitHub poll loop and all derived runner/job/action state.
///
/// **Concurrency model**
/// - The actor runs on its own executor (background thread).
/// - `preferencesStore` and `scopeStore` are `@MainActor`-isolated `Sendable` protocol
///   values; any read of their properties must happen inside `await MainActor.run { }`.
/// - After every fetch cycle, results are pushed to the injected `RunnerViewModel` on the
///   main actor via `await MainActor.run { }`. SwiftUI's `@Observable` machinery
///   picks up the mutation automatically — no Combine `PassthroughSubject` needed.
/// - `LocalRunnerStore` is an `actor`; its state is read via the main-actor snapshot
///   pushed to `RunnerViewModel`, not by crossing the actor boundary synchronously.
/// - Status-icon refresh is triggered via the injected `onStatusUpdate` callback rather
///   than accessing `NSApp.delegate` directly (PR Principle #4: no singleton access
///   inside actor bodies).
actor RunnerStore {

    // MARK: - State

    /// Runners currently shown in the panel.
    private(set) var runners: [Runner] = []
    /// Jobs currently shown in the panel, including dimmed completed entries.
    private(set) var jobs: [ActiveJob] = []
    /// Workflow action groups currently shown in the panel.
    private(set) var actions: [WorkflowActionGroup] = []

    /// Live-job snapshot from the previous poll, used to detect vanished jobs.
    private var prevLiveJobs: [Int: ActiveJob] = [:]
    /// Completed-job cache keyed by job ID; capped at `PollResultBuilder.jobCacheLimit`.
    private var completedCache: [Int: ActiveJob] = [:]
    /// Live-group snapshot from the previous poll, used to detect vanished groups.
    private var prevLiveGroups: [String: WorkflowActionGroup] = [:]
    /// Group cache keyed by group ID; capped at `PollResultBuilder.groupCacheLimit`.
    private var actionGroupCache: [String: WorkflowActionGroup] = [:]
    /// IDs of action groups whose failure hook has already fired.
    ///
    /// Kept separate from `actionGroupCache` so that cache eviction does not re-arm
    /// the hook for old completed groups still present in GitHub's last-completed feed.
    private var seenGroupIDs: Set<String> = []

    /// Whether the GitHub API is currently rate-limiting this client.
    private(set) var isRateLimited = false
    /// The exact moment the current rate-limit window expires, or `nil` when no
    /// rate-limit is active or the reset time is unknown.
    /// Assigned in `applyFetchResult` and mirrored to `RunnerViewModel`;
    /// consumed externally via the view model. periphery:ignore
    private(set) var rateLimitResetDate: Date?

    /// Owns the three structured `Task` handles for the poll loop.
    /// A dedicated coordinator type is used instead of three raw `Task?` properties so
    /// that `start()`, `nextPollInterval()`, and the observation helpers can be moved
    /// into `RunnerStore+PollLoop.swift` without widening their access to `internal`.
    /// The coordinator itself is `internal`; the individual task slots remain private
    /// to `PollLoopCoordinator.swift`.
    private let pollLoop = PollLoopCoordinator()

    /// The view model this store pushes updates into.
    private let viewModel: RunnerViewModel
    /// Injected reference to the local runner store — avoids singleton cross-references
    /// inside the actor body (Swift 6 / PR #1303 requirement).
    private let localRunnerStore: LocalRunnerStore
    /// Injected preferences store. Provides `pollingInterval`.
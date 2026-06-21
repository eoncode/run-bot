// APICallCounterViewModel.swift
// RunnerBar
//
// @Observable view-model exposing live GitHub API call-counter state
// for the Settings panel (P2 — Async/Await and @Observable for Data Flow).
import Foundation
import Observation
import RunnerBarCore
import SwiftUI

// MARK: - TaskBox

/// Reference-type wrapper that holds a cancellable polling `Task`.
///
/// `@Observable` expands stored properties via `@ObservationTracked`.
/// Neither `nonisolated` nor plain `nonisolated(unsafe)` on a bare
/// `Task?` property compiles cleanly inside a `@MainActor @Observable`
/// class under Swift 6 strict concurrency — the macro-expanded
/// `_$observationRegistrar` access conflicts.
/// Wrapping the task in a `final class` makes it opaque to the macro,
/// and marking the stored property `nonisolated(unsafe)` lets `deinit`
/// call `cancel()` without a main-actor hop.
///
/// **Invariant:** `task` must only ever be *written* from `@MainActor`
/// context. `deinit` only *reads* it to call `cancel()`, which is safe
/// because `Task` is `Sendable` and `cancel()` is concurrency-safe.
private final class TaskBox: @unchecked Sendable {
    /// The structured polling task, or `nil` before polling has started.
    /// Invariant: must only be written from `@MainActor` context.
    var task: Task<Void, Never>?
    /// Creates an empty `TaskBox` with no active polling task.
    init() {
        // Default property initializers fully define state.
    }
}

// MARK: - APICallCounterViewModel

/// View-model that polls `APICallCounterProtocol` every `pollingInterval` seconds
/// and exposes derived display state for `APICallCounterRow`.
@Observable
@MainActor
public final class APICallCounterViewModel {
    /// Interval between counter refreshes.
    private static let pollingInterval: Duration = .seconds(5)

    /// Latest atomic snapshot from the counter actor.
    public private(set) var snap = APICallCounterSnapshot(
        count: 0,
        limit: APICallCounter.hourlyLimit
    )

    /// The counter actor injected at init time (P7).
    private let counter: any APICallCounterProtocol

    /// Box holding the structured polling task so `deinit` can cancel it.
    ///
    /// Marked `nonisolated(unsafe)` so the Swift 6 nonisolated `deinit`
    /// can read `taskBox.task` to call `cancel()` without a main-actor hop.
    /// Safe because `task` is only written from `@MainActor` context
    /// (in `startPolling()`) and `Task.cancel()` is concurrency-safe.
    nonisolated(unsafe) private let taskBox = TaskBox()

    /// Creates the view-model.
    /// - Parameter counter: Counter to poll. Defaults to `apiCallCounter`.
    public init(counter: any APICallCounterProtocol = apiCallCounter) {
        self.counter = counter
        startPolling()
    }

    deinit { taskBox.task?.cancel() }

    // MARK: - Derived display state

    /// Human-readable counter label, e.g. `"410 / 5,000"`.
    public var label: String {
        "\(snap.count.formatted()) / \(snap.limit.formatted())"
    }

    /// Progress bar and counter tint: green → yellow → red as usage rises.
    public var statusColor: Color {
        switch snap.fraction {
        case ..<0.60: .green
        case ..<0.85: .yellow
        default: .red
        }
    }

    // MARK: - Private

    /// Starts a structured polling loop that refreshes `snap` every `pollingInterval`.
    ///
    /// `self` is only held strongly during the actor hop for `snapshot()` —
    /// released before sleeping so `deinit` can fire immediately on view disappear.
    private func startPolling() {
        taskBox.task = Task { [weak self] in
            while !Task.isCancelled {
                if let self { self.snap = await self.counter.snapshot() }
                do {
                    try await Task.sleep(for: Self.pollingInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
            }
        }
    }
}

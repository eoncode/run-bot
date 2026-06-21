// APICallCounterViewModel.swift
// RunnerBar
//
// @Observable view-model that exposes live GitHub API call-counter state
// for the Settings panel (P2 — Async/Await and @Observable for Data Flow).
//
// Injects `any APICallCounterProtocol` (P7 — Protocol-Oriented DI) so the
// view can be driven by a spy in unit tests without touching the real actor.
//
// Polling uses Task + Task.sleep(for:) (P9 — Structured Concurrency for
// Stateful Timers), not DispatchQueue.asyncAfter.
import Foundation
import Observation
import RunnerBarCore
import SwiftUI

// MARK: - TaskBox

/// Reference-type wrapper that stores a cancellable `Task`.
///
/// `@Observable` expands every stored property of the annotated type via the
/// `@ObservationTracked` macro. Both `nonisolated` and `nonisolated(unsafe)`
/// are forbidden on such expanded stored properties in Swift 6:
/// - `nonisolated(unsafe)` — "has no effect on Sendable Task, use nonisolated"
/// - `nonisolated` — "cannot be applied to a mutable stored property"
///
/// Wrapping the `Task` in a `final class` sidesteps the constraint entirely:
/// the `@Observable` macro does not descend into reference-type properties,
/// so `TaskBox` is invisible to `@ObservationTracked`. `deinit` can then
/// reach into the box without any actor-isolation violation.
private final class TaskBox {
    var task: Task<Void, Never>?
    init() {}
}

// MARK: - APICallCounterViewModel

/// View-model that polls `APICallCounterProtocol` every 5 seconds and
/// exposes derived display state for `APICallCounterRow`.
@Observable
@MainActor
public final class APICallCounterViewModel {
    /// Latest atomic snapshot from the counter actor.
    public private(set) var snap = APICallCounterSnapshot(
        count: 0,
        limit: APICallCounter.hourlyLimit
    )

    /// The counter actor. Defaulted to the shared production instance;
    /// override in tests via the initialiser.
    private let counter: any APICallCounterProtocol

    /// Reference-type box holding the structured polling task.
    ///
    /// Stored as a `final class` so that `@Observable`'s `@ObservationTracked`
    /// macro expansion does not touch it, and `deinit` can cancel via
    /// `taskBox.task?.cancel()` without any actor-isolation violation.
    private let taskBox = TaskBox()

    /// Creates the view-model.
    ///
    /// - Parameter counter: Counter actor to poll. Defaults to the shared
    ///   production `apiCallCounter`.
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

    /// Starts a structured polling loop that refreshes `snap` every 5 seconds.
    private func startPolling() {
        taskBox.task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.snap = await self.counter.snapshot()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

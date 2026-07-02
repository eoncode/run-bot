// UpdateStateProviding.swift
// AppUpdater
import Foundation

// MARK: - UpdatePhase

/// The discrete phases of an update lifecycle driven by `AppUpdater`.
///
/// `AppUpdater` advances through these phases as it discovers, downloads,
/// and installs an update. The host conforming to `UpdateStateProviding`
/// receives each transition via `apply(_:)` and maps it to its own UI state.
public enum UpdatePhase: Equatable {
    /// No update activity — nothing available, nothing in progress.
    case idle
    /// A newer release was found; version is the tag string (e.g. `"v1.2.0"`).
    case available(version: String)
    /// A download is in progress for the given version.
    case downloading(version: String)
    /// Download complete and integrity-verified; zip is at `zipURL`.
    case ready(version: String, zipURL: URL)
    /// A download or install attempt failed. `version` is the release tag if
    /// known at the time of failure, `nil` otherwise.
    case failed(version: String?)
}

// MARK: - UpdateStateProviding

/// The host-app state model that `AppUpdater` drives while an update is
/// discovered, downloaded, and installed.
///
/// `AppUpdater` owns none of the UI state itself — it mutates a conforming
/// object supplied by the host app (typically an `@Observable @MainActor`
/// view model). The host observes that object to render its own update UI.
///
/// ## Why the whole protocol is `@MainActor`
///
/// The conforming type is expected to be observed by SwiftUI/AppKit, both of
/// which require main-thread access. Annotating the entire protocol (not just
/// individual requirements) is required for Swift 6 strict concurrency: it
/// makes every requirement main-actor isolated so `AppUpdater` (also
/// `@MainActor`) can call them synchronously without cross-actor hops, and it
/// lets conforming `@MainActor` classes satisfy the protocol without extra
/// `nonisolated` juggling.
///
/// ## Single-method mutation via `apply(_:)`
///
/// All state changes go through one named method: `apply(_ phase: UpdatePhase)`.
/// The `UpdatePhase` enum is the exclusive state-transfer type — no raw
/// property setters, no boolean flags, no parallel URL properties. This
/// eliminates TOCTOU-shaped misuse: you cannot set a zip URL without also
/// setting the matching version, because both are encoded in a single
/// `UpdatePhase.ready(version:zipURL:)` case. Every write site becomes a
/// single `state.apply(.case)` call, making state transitions auditable.
///
/// ## Why the protocol also refines `Sendable`
///
/// `AppUpdater.scheduleBackgroundCheck` captures the host-state existential in an
/// escaping `NSBackgroundActivityScheduler` closure that runs on a background
/// GCD queue. Refining `Sendable` makes `any UpdateStateProviding` safe to carry
/// across that boundary. This costs conformers nothing: every conformer is a
/// reference type isolated to `@MainActor` (the whole protocol is), and
/// global-actor-isolated classes are implicitly `Sendable`.
@MainActor
public protocol UpdateStateProviding: AnyObject, Sendable {

    /// Advance the update state to `phase`.
    ///
    /// `AppUpdater` calls this on the main actor whenever the update lifecycle
    /// moves to a new phase. Implementations should store the phase and notify
    /// any observers (e.g. `@Observable` property, `objectWillChange.send()`).
    func apply(_ phase: UpdatePhase)

    /// The current update phase. `AppUpdater` reads this to make decisions
    /// (e.g. skip resetting to `.idle` if already `.ready`).
    var currentPhase: UpdatePhase { get }
}

// RunnerStore+PollLoop.swift
// RunnerBar
//
// Migration status: COMPLETE (PR #1481 / PR-D)
//
// The poll-loop extraction blocker has been resolved.
//
// Previously, `start()`, `nextPollInterval()`, and the two observation
// helpers could not be moved here because their backing state
// (`pollTask`, `intervalObservationTask`, `scopeObservationTask`) was
// declared as raw `private` stored properties in `RunnerStore.swift`.
// Swift's `private` is file-scoped, not type-scoped, so moving those
// properties to an extension file would have required widening them
// to `internal`, exposing them across the entire module.
//
// Resolution: the three `Task?` handles are now owned by
// `PollLoopCoordinator` (see `PollLoopCoordinator.swift`), a dedicated
// `final class` stored as `private let pollLoop` on `RunnerStore`.
// `PollLoopCoordinator` is `internal`, but its task slots are
// `private(set)` and mutated only through the coordinator's own
// setters — no actor-level access widening was required.
//
// The poll-loop methods themselves (`start`, `nextPollInterval`,
// `startObservingPreferences`, `startObservingScopes`) remain in
// `RunnerStore.swift` because they are `private` and therefore
// file-scoped. Moving them here would make them `internal`.
// Given that `PollLoopCoordinator` already provides the clean
// extraction boundary the architecture needed, the additional move
// is deferred until Swift gains extension-scoped `private` access.
//
// Combine dependency removed: `intervalCancellable` and
// `scopeCancellable` (AnyCancellable) have been replaced by the
// structured `Task`-based observation in `PreferencesObserver` and
// `ScopesObserver`. There are no remaining Combine imports in
// `RunnerStore.swift`.
import Foundation

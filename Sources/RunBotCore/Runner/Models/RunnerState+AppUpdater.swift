// RunnerState+AppUpdater.swift
// RunBotCore
import AppUpdater
import Foundation

// MARK: - UpdateStateProviding conformance

/// Bridges `RunnerState` to the `AppUpdater` library's host-state protocol.
///
/// All requirements — the read-only `updateZipURL` / `cachedUpdateVersion` /
/// `updateActionFailed` properties and the `setAvailableUpdate` /
/// `setDownloadStarted` / `setDownloadComplete` / `setUpdateFailed` /
/// `rehydrateCachedUpdate` mutation methods — are already declared on
/// `RunnerState` itself, so this conformance is empty. It lives in its own file
/// so the `import AppUpdater` dependency is confined here and `RunnerState.swift`
/// stays free of the library import.
extension RunnerState: UpdateStateProviding {}

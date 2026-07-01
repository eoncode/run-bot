// RunnerState+AppUpdater.swift
// RunBotCore
import AppUpdater
import Foundation

// MARK: - UpdateStateProviding conformance

/// Bridges `RunnerState` to the `AppUpdater` library's host-state protocol.
///
/// All requirements — the read-only `updateZipURL` / `cachedUpdateVersion` /
/// `updateActionFailed` / `updateAssetMissing` properties and the
/// `setAvailableUpdate` / `setDownloadStarted` / `setDownloadComplete` /
/// `setUpdateFailed` / `setAssetMissing` / `rehydrateCachedUpdate` mutation
/// methods — are already declared on `RunnerState` itself.
/// `clearDownloadState` is satisfied by the default implementation in
/// `UpdateStateProviding` (delegates to `setDownloadStarted`).
///
/// This conformance is empty and lives in its own file so the `import AppUpdater`
/// dependency is confined here and `RunnerState.swift` stays free of the library
/// import.
extension RunnerState: UpdateStateProviding {}

// MockUpdateState.swift
// AppUpdater
import Foundation
@testable import AppUpdater

// MARK: - MockUpdateState

/// A recording test double for `UpdateStateProviding`.
///
/// Every protocol requirement is satisfied by mutating the read-only backing
/// properties and bumping a per-method call counter, so tests can assert both
/// the resulting state and which mutation hooks `AppUpdater` invoked.
@MainActor
final class MockUpdateState: UpdateStateProviding {

    // Read-only protocol properties (mutated only through the methods below).
    private(set) var updateZipURL: URL?
    private(set) var cachedUpdateVersion: String?
    private(set) var updateActionFailed: Bool = false

    // Recorded interactions.
    private(set) var availableUpdates: [String?] = []
    private(set) var downloadStartedCount = 0
    private(set) var downloadCompleteCount = 0
    private(set) var updateFailedCount = 0
    private(set) var rehydrateCount = 0

    func setAvailableUpdate(_ version: String?) {
        availableUpdates.append(version)
    }

    func setDownloadStarted() {
        downloadStartedCount += 1
        updateZipURL = nil
        cachedUpdateVersion = nil
        updateActionFailed = false
    }

    func setDownloadComplete(zipURL: URL, version: String) {
        downloadCompleteCount += 1
        updateZipURL = zipURL
        cachedUpdateVersion = version
        updateActionFailed = false
    }

    func setUpdateFailed() {
        updateFailedCount += 1
        updateActionFailed = true
    }

    func rehydrateCachedUpdate(zipURL: URL, version: String) {
        rehydrateCount += 1
        updateZipURL = zipURL
        cachedUpdateVersion = version
        updateActionFailed = false
    }
}

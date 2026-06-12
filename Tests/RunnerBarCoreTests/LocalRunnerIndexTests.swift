// LocalRunnerIndexTests.swift
// RunnerBarCoreTests
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - LocalRunnerIndexTests

/// Tests for `LocalRunnerIndex` — the `UserDefaults`-backed name → install-path persistence layer.
///
/// Each test creates a UUID-namespaced `UserDefaults` suite via `makeIndex()` and tears it
/// down with `removePersistentDomain` in a `defer` block, ensuring full isolation even
/// under Swift Testing’s parallel runner.
@Suite("LocalRunnerIndex")
struct LocalRunnerIndexTests {

    // MARK: - Helpers

    /// Creates a fresh isolated `LocalRunnerIndex` backed by a UUID-namespaced `UserDefaults` suite.
    /// The caller is responsible for calling `defaults.removePersistentDomain(forName: suiteName)`
    /// when the test completes.
    private func makeIndex() -> (index: LocalRunnerIndex, defaults: UserDefaults, suiteName: String) {
        let suiteName = "com.runnerbar.tests.LocalRunnerIndex.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (LocalRunnerIndex(defaults: defaults), defaults, suiteName)
    }

    // MARK: - register

    /// `register` stores the install path and makes it immediately readable.
    @Test func registerStoresPath() {
        let (index, defaults, suiteName) = makeIndex()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        index.register(name: "my-runner", installPath: "/opt/runners/my-runner")
        #expect(index.runnerIndex["my-runner"] == "/opt/runners/my-runner")
    }

    /// `register` called twice with the same name updates the path.
    @Test func registerOverwritesExistingEntry() {
        let (index, defaults, suiteName) = makeIndex()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        index.register(name: "runner-a", installPath: "/old/path")
        index.register(name: "runner-a", installPath: "/new/path")
        #expect(index.runnerIndex["runner-a"] == "/new/path")
    }

    /// Multiple runners can be registered independently.
    @Test func registerMultipleRunners() {
        let (index, defaults, suiteName) = makeIndex()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        index.register(name: "alpha", installPath: "/runners/alpha")
        index.register(name: "beta", installPath: "/runners/beta")
        #expect(index.runnerIndex.count == 2)
        #expect(index.runnerIndex["alpha"] == "/runners/alpha")
        #expect(index.runnerIndex["beta"] == "/runners/beta")
    }

    // MARK: - unregister

    /// `unregister` removes a previously registered runner.
    @Test func unregisterRemovesEntry() {
        let (index, defaults, suiteName) = makeIndex()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        index.register(name: "to-remove", installPath: "/path")
        index.unregister(name: "to-remove")
        #expect(index.runnerIndex["to-remove"] == nil)
    }

    /// `unregister` on an unknown name is a no-op (does not crash).
    @Test func unregisterUnknownNameIsNoop() {
        let (index, defaults, suiteName) = makeIndex()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        index.unregister(name: "does-not-exist")
        #expect(index.runnerIndex.isEmpty)
    }

    /// `unregister` only removes the targeted runner, leaving others intact.
    @Test func unregisterLeavesOthersIntact() {
        let (index, defaults, suiteName) = makeIndex()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        index.register(name: "keep", installPath: "/keep")
        index.register(name: "remove", installPath: "/remove")
        index.unregister(name: "remove")
        #expect(index.runnerIndex["keep"] == "/keep")
        #expect(index.runnerIndex["remove"] == nil)
    }

    // MARK: - Persistence (UserDefaults round-trip)

    /// A new `LocalRunnerIndex` instance backed by the same suite reads back entries
    /// written by a previous instance — verifying UserDefaults persistence.
    @Test func persistenceRoundTrip() {
        let suiteName = "com.runnerbar.tests.LocalRunnerIndex.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = LocalRunnerIndex(defaults: defaults)
        writer.register(name: "persistent-runner", installPath: "/persistent/path")
        let reader = LocalRunnerIndex(defaults: defaults)
        #expect(reader.runnerIndex["persistent-runner"] == "/persistent/path")
    }
}

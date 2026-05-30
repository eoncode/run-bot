// RunnerViewModel.swift
// RunnerBar
import Foundation
import Combine

// MARK: - RunnerViewModel
//
// Bridges RunnerStore + LocalRunnerStore into @Published properties consumed by SwiftUI views.
// reload() is called on every displayTick (≈1 Hz) from the panel view.

final class RunnerViewModel: ObservableObject {
    // MARK: - Shared singleton
    @MainActor static let shared = RunnerViewModel()

    // MARK: - Published state
    @Published var runners: [RunnerModel] = []
    @Published var jobs: [ActiveJob] = []
    @Published var actions: [WorkflowActionGroup] = []
    @Published var localRunners: [RunnerModel] = []
    @Published var isRateLimited: Bool = false
    @Published var rateLimitResetDate: Date?

    // MARK: - Dependency injection (for tests)
    var localRunnerStore: LocalRunnerStore?

    // MARK: - Reload

    func reload() {
        let localStore = localRunnerStore ?? LocalRunnerStore.shared
        let store = RunnerStore.shared
        log("RunnerViewModel › reload — actions=\(store.actions.count) jobs=\(store.jobs.count) runners=\(store.runners.count) localRunners=\(localStore.runners.count)")
        runners = store.runners
        jobs = store.jobs
        actions = store.actions
        localRunners = localStore.runners
        isRateLimited = store.isRateLimited
        rateLimitResetDate = store.rateLimitResetDate
        localStore.refresh()
    }
}

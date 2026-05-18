import AppKit
import Combine
import Foundation

// MARK: - AggregateStatus

enum AggregateStatus {
    case allOnline
    case someOffline
    case allOffline
    var dot: String {
        switch self {
        case .allOnline: return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
        }
    }
    var symbolName: String {
        switch self {
        case .allOnline: return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline: return "circle"
        }
    }
}

// MARK: - RunnerStore

final class RunnerStore {
    static let shared = RunnerStore()

    private(set) var runners: [Runner] = []
    private(set) var jobs: [ActiveJob] = []
    private(set) var actions: [ActionGroup] = []

    private var prevLiveJobs: [Int: ActiveJob] = [:]
    private var completedCache: [Int: ActiveJob] = [:]
    private var prevLiveGroups: [String: ActionGroup] = [:]
    private var actionGroupCache: [String: ActionGroup] = [:]

    private(set) var isRateLimited = false
    private var timer: Timer?
    private var intervalCancellable: AnyCancellable?
    var onChange: (() -> Void)?

    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let onlineCount = runners.filter { $0.status == "online" }.count
        if onlineCount == runners.count { return .allOnline }
        if onlineCount == 0 { return .allOffline }
        return .someOffline
    }

    private init() {
        log("RunnerStore › init")
        intervalCancellable = SettingsStore.shared.$pollingInterval
            .dropFirst(1)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newInterval in
                log("RunnerStore › pollingInterval changed to \(newInterval) — rescheduling timer")
                self?.scheduleTimer()
            }
    }

    func start() {
        let scopes = ScopeStore.shared.scopes
        log("RunnerStore › start — scopes=\(scopes)")
        if scopes.isEmpty {
            log("RunnerStore › ⚠️ start called but ScopeStore.shared.scopes is EMPTY — actions will not load")
        }
        timer?.invalidate()
        log("RunnerStore › start — calling fetch()")
        fetch()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let hasActiveActions = actions.contains {
            $0.groupStatus == .inProgress || $0.groupStatus == .queued
        }
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, SettingsStore.shared.pollingInterval)
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerStore › scheduleTimer — next poll in \(Int(interval))s (hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle))")
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            log("RunnerStore › timer fired — calling fetch()")
            self?.fetch()
        }
    }

    func fetch() {
        let scopesSnapshot = ScopeStore.shared.scopes
        log("RunnerStore › fetch ENTER — scopesSnapshot=\(scopesSnapshot) thread=\(Thread.isMainThread ? "main" : "bg")")
        if scopesSnapshot.isEmpty {
            log("RunnerStore › ⚠️ fetch — scopes snapshot is EMPTY — buildGroupState will produce no actions")
        }
        let snapPrev = prevLiveJobs
        let snapCache = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache
        log("RunnerStore › fetch — dispatching background block (qos=.background) snapPrev=\(snapPrev.count) snapCache=\(snapCache.count) snapPrevGroups=\(snapPrevGroups.count) snapGroupCache=\(snapGroupCache.count)")
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else {
                log("RunnerStore › fetch background — self is nil, aborting")
                return
            }
            log("RunnerStore › fetch background — START thread=\(Thread.current)")
            ghIsRateLimited = false
            log("RunnerStore › fetch background — calling fetchAndEnrichRunners()")
            let enrichedRunners = self.fetchAndEnrichRunners()
            log("RunnerStore › fetch background — fetchAndEnrichRunners() returned \(enrichedRunners.count) runner(s)")
            log("RunnerStore › fetch background — calling buildJobState()")
            let jobResult = self.buildJobState(snapPrev: snapPrev, snapCache: snapCache)
            log("RunnerStore › fetch background — buildJobState() returned display=\(jobResult.display.count) newCache=\(jobResult.newCache.count)")
            log("RunnerStore › fetch background — calling buildGroupState()")
            let groupResult = self.buildGroupState(
                snapPrevGroups: snapPrevGroups,
                snapGroupCache: snapGroupCache,
                jobCache: jobResult.newCache
            )
            log("RunnerStore › fetch background — buildGroupState() returned display=\(groupResult.display.count)")
            log("RunnerStore › fetch background — dispatching to main thread")
            DispatchQueue.main.async {
                log("RunnerStore › fetch main — assigning results: runners=\(enrichedRunners.count) jobs=\(jobResult.display.count) actions=\(groupResult.display.count)")
                self.runners = enrichedRunners
                self.jobs = jobResult.display
                self.completedCache = jobResult.newCache
                self.prevLiveJobs = jobResult.newPrevLive
                self.actions = groupResult.display
                self.actionGroupCache = groupResult.newGroupCache
                self.prevLiveGroups = groupResult.newPrevLiveGroups
                self.isRateLimited = ghIsRateLimited
                log("RunnerStore › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) isRateLimited=\(ghIsRateLimited)")
                log("RunnerStore › fetch complete — calling onChange (isNil=\(self.onChange == nil))")
                self.onChange?()
                log("RunnerStore › fetch complete — onChange called, scheduling next timer")
                self.scheduleTimer()
            }
        }
        log("RunnerStore › fetch EXIT (background block dispatched)")
    }

    func fetchAndEnrichRunners() -> [Runner] {
        log("RunnerStore › fetchAndEnrichRunners ENTER")
        var allRunners: [Runner] = []
        let scopes = ScopeStore.shared.scopes
        log("RunnerStore › fetchAndEnrichRunners — scopes=\(scopes)")
        for scope in scopes {
            log("RunnerStore › fetchAndEnrichRunners — fetching runners for scope=\(scope)")
            let fetched = fetchRunners(for: scope)
            log("RunnerStore › fetchAndEnrichRunners — scope=\(scope) returned \(fetched.count) runner(s)")
            allRunners.append(contentsOf: fetched)
        }
        log("RunnerStore › fetchAndEnrichRunners — total runners before metrics=\(allRunners.count) — calling allWorkerMetrics()")
        let metrics = allWorkerMetrics()
        log("RunnerStore › fetchAndEnrichRunners — allWorkerMetrics() returned \(metrics.count) metric(s)")
        var busyRunners = allRunners.filter { $0.busy }
        var idleRunners = allRunners.filter { !$0.busy }
        log("RunnerStore › fetchAndEnrichRunners — busy=\(busyRunners.count) idle=\(idleRunners.count)")
        for idx in busyRunners.indices {
            busyRunners[idx].metrics = idx < metrics.count ? metrics[idx] : nil
        }
        for idx in idleRunners.indices {
            let slotIdx = busyRunners.count + idx
            idleRunners[idx].metrics = slotIdx < metrics.count ? metrics[slotIdx] : nil
        }
        let result = busyRunners + idleRunners
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}

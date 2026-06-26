// PollResultBuilder.swift
// RunnerBarCore
import Collections
import Foundation
import OrderedCollections

// MARK: - GroupStateDeps

/// Injected dependencies for `PollResultBuilder.buildGroupState`.
public struct GroupStateDeps: Sendable {
    public let fetchGroups: @Sendable ([String: WorkflowActionGroup]) async -> [WorkflowActionGroup]
    public let scopeFromGroup: @Sendable (WorkflowActionGroup) -> String
    public let fireFailureHook: @Sendable (WorkflowActionGroup, String) async -> Void
    public let enrichJobs: @Sendable ([ActiveJob]) async -> [ActiveJob]

    public init(
        fetchGroups: @escaping @Sendable ([String: WorkflowActionGroup]) async -> [WorkflowActionGroup],
        scopeFromGroup: @escaping @Sendable (WorkflowActionGroup) -> String,
        fireFailureHook: @escaping @Sendable (WorkflowActionGroup, String) async -> Void,
        enrichJobs: @escaping @Sendable ([ActiveJob]) async -> [ActiveJob]
    ) {
        self.fetchGroups = fetchGroups
        self.scopeFromGroup = scopeFromGroup
        self.fireFailureHook = fireFailureHook
        self.enrichJobs = enrichJobs
    }
}

// MARK: - FreezeVanishedConfig

/// State parameters for `PollResultBuilder.freezeVanishedGroups`.
public struct FreezeVanishedConfig: Sendable {
    public let snapPrev: [String: WorkflowActionGroup]
    public let liveIDs: Set<String>
    public let now: Date

    public init(
        snapPrev: [String: WorkflowActionGroup],
        liveIDs: Set<String>,
        now: Date
    ) {
        self.snapPrev = snapPrev
        self.liveIDs = liveIDs
        self.now = now
    }
}

// MARK: - PollResultBuilder

/// Pure state-building logic extracted from RunnerStore.
public struct PollResultBuilder {

    // MARK: - Cache limits

    public static let jobCacheLimit = 3
    public static let jobDisplayLimit = 10
    public static let groupCacheLimit = 30
    public static let groupDisplayLimit = 10
    public static let seenGroupIDsLimit = 200

    // MARK: - Job state

    public static func buildJobState(
        snapPrev: [Int: ActiveJob],
        snapCache: [Int: ActiveJob],
        fetchJobs: @Sendable () async -> [ActiveJob],
        backfill: @Sendable (inout [Int: ActiveJob]) async -> Void
    ) async -> JobPollResult {
        let allFetched: [ActiveJob] = await fetchJobs()
        let liveJobs: [ActiveJob] = allFetched.filter { $0.conclusion == nil && $0.status != .completed }
        let freshDone: [ActiveJob] = allFetched.filter { $0.conclusion != nil || $0.status == .completed }
        let liveIDs: Set<Int> = Set(liveJobs.map { $0.id })
        let now = Date()
        var newCache: [Int: ActiveJob] = snapCache
        applyVanishedJobs(snapPrev: snapPrev, liveIDs: liveIDs, now: now, into: &newCache)
        for job in freshDone {
            newCache[job.id] = job.asCompleted(at: now)
        }
        trimJobCache(&newCache, limit: jobCacheLimit)
        await backfill(&newCache)
        let newPrevLive: [Int: ActiveJob] = [Int: ActiveJob](uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })
        let display = buildJobDisplay(live: liveJobs, cache: newCache)
        let inProgCount = liveJobs.filter { $0.status == .inProgress }.count
        let queuedCount = liveJobs.filter { $0.status == .queued }.count
        log(
            "PollResultBuilder › \(inProgCount) in_progress \(queuedCount) queued"
                + " | cache: \(newCache.count) | display: \(display.count)",
            category: .runner
        )
        return JobPollResult(display: display, newCache: newCache, newPrevLive: newPrevLive)
    }

    // MARK: - Group state

    public static func buildGroupState(
        snapPrevGroups: [String: WorkflowActionGroup],
        snapGroupCache: [String: WorkflowActionGroup],
        snapSeenGroupIDs: OrderedSet<String> = OrderedSet(),
        deps: GroupStateDeps
    ) async -> GroupPollResult {
        log("PollResultBuilder › buildGroupState — snapPrevGroups=\(snapPrevGroups.count) snapGroupCache=\(snapGroupCache.count) snapSeenGroupIDs=\(snapSeenGroupIDs.count)", category: .runner)
        let shaKeyedCache = makeShaKeyedCache(snapGroupCache)
        let allFetched = await deps.fetchGroups(shaKeyedCache)
        if allFetched.isEmpty {
            log("PollResultBuilder › buildGroupState — ⚠️ fetchGroups returned 0 groups; activeScopes may be empty or all scopes are unreachable", category: .runner)
        }
        log("PollResultBuilder › buildGroupState — allFetched=\(allFetched.count)", category: .runner)
        let liveGroups = allFetched.filter { $0.groupStatus != .completed }
        let doneGroups = allFetched.filter { $0.groupStatus == .completed }
        let liveIDs = Set(liveGroups.map { $0.id })
        let now = Date()
        var newCache = evictFreshShas(from: snapGroupCache, freshGroups: allFetched)
        var newSeenGroupIDs = snapSeenGroupIDs
        for group in doneGroups {
            let isNew = !newSeenGroupIDs.contains(group.id)
            let runSummary = group.runs.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(separator: ", ")
            log("PollResultBuilder › doneGroups — groupID=\(group.id) isNew=\(isNew) runs=[\(runSummary)]", category: .runner)
            if isNew {
                let scope = deps.scopeFromGroup(group)
                log("PollResultBuilder › doneGroups — groupID=\(group.id) isNew=true → scope=\(scope)", category: .runner)
                let shouldFire = group.runs.contains { $0.conclusion?.isHookConclusion == true }
                if shouldFire {
                    await deps.fireFailureHook(group, scope)
                }
                newSeenGroupIDs.append(group.id)
            }
            newCache[group.id] = group.copying(isDimmed: true)
        }
        let freezeConfig = FreezeVanishedConfig(snapPrev: snapPrevGroups, liveIDs: liveIDs, now: now)
        await freezeVanishedGroups(
            config: freezeConfig,
            into: &newCache,
            seenGroupIDs: &newSeenGroupIDs,
            scopeFromGroup: deps.scopeFromGroup,
            fireFailureHook: deps.fireFailureHook
        )
        trimGroupCache(&newCache, limit: groupCacheLimit)
        trimSeenGroupIDs(&newSeenGroupIDs, limit: seenGroupIDsLimit)
        let newPrevLive = [String: WorkflowActionGroup](uniqueKeysWithValues: liveGroups.map { ($0.id, $0) })
        let display = buildGroupDisplay(live: liveGroups, cache: newCache)
        let inProgCount = liveGroups.filter { $0.groupStatus == .inProgress }.count
        let queuedCount = liveGroups.filter { $0.groupStatus == .queued }.count
        let loadingCount = liveGroups.filter { $0.groupStatus == .loading }.count
        log(
            "PollResultBuilder › groups: \(inProgCount) in_progress \(queuedCount) queued \(loadingCount) loading"
                + " | cache: \(newCache.count) | seenIDs: \(newSeenGroupIDs.count) | display: \(display.count)",
            category: .runner
        )
        let enriched: [WorkflowActionGroup] = await withTaskGroup(
            of: (Int, WorkflowActionGroup).self
        ) { group in
            for (idx, actionGroup) in display.enumerated() {
                group.addTask { (idx, actionGroup.withJobs(await deps.enrichJobs(actionGroup.jobs))) }
            }
            var out: [(Int, WorkflowActionGroup)] = []
            for await pair in group { out.append(pair) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        let enrichedCache: [String: WorkflowActionGroup] = await withTaskGroup(
            of: (String, WorkflowActionGroup).self
        ) { group in
            for (key, actionGroup) in newCache {
                group.addTask { (key, actionGroup.withJobs(await deps.enrichJobs(actionGroup.jobs))) }
            }
            var out: [String: WorkflowActionGroup] = [:]
            for await (key, actionGroup) in group { out[key] = actionGroup }
            return out
        }
        return GroupPollResult(
            display: enriched,
            newGroupCache: enrichedCache,
            newPrevLiveGroups: newPrevLive,
            newSeenGroupIDs: newSeenGroupIDs
        )
    }

    // MARK: - Job helpers

    public static func applyVanishedJobs(
        snapPrev: [Int: ActiveJob],
        liveIDs: Set<Int>,
        now: Date,
        into cache: inout [Int: ActiveJob]
    ) {
        for (jobID, job) in snapPrev where !liveIDs.contains(jobID) {
            guard cache[jobID] == nil else { continue }
            cache[jobID] = job.asCompleted(at: now)
        }
    }

    public static func trimJobCache(_ cache: inout [Int: ActiveJob], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        cache = [Int: ActiveJob](uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    public static func buildJobDisplay(live: [ActiveJob], cache: [Int: ActiveJob]) -> [ActiveJob] {
        let inProgress: [ActiveJob] = live.filter { $0.status == .inProgress }
        let queued: [ActiveJob] = live.filter { $0.status == .queued }
        let cached: [ActiveJob] = cache.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        let liveJobIDs = Set(live.map { $0.id })
        var display: [ActiveJob] = []
        display.appendUpTo(jobDisplayLimit, from: inProgress)
        display.appendUpTo(jobDisplayLimit, from: queued)
        display.appendUpTo(jobDisplayLimit, from: cached) { !liveJobIDs.contains($0.id) }
        return display
    }

    // MARK: - Group helpers

    public static func makeShaKeyedCache(_ cache: [String: WorkflowActionGroup]) -> [String: WorkflowActionGroup] {
        Dictionary(
            cache.values.map { ($0.headSha, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.id > rhs.id ? lhs : rhs }
        )
    }

    public static func evictFreshShas(
        from cache: [String: WorkflowActionGroup],
        freshGroups: [WorkflowActionGroup]
    ) -> [String: WorkflowActionGroup] {
        let freshShas = Set(freshGroups.map { $0.headSha })
        return cache.filter { !freshShas.contains($0.value.headSha) }
    }

    public static func freezeVanishedGroups(
        config: FreezeVanishedConfig,
        into cache: inout [String: WorkflowActionGroup],
        seenGroupIDs: inout OrderedSet<String>,
        scopeFromGroup: @Sendable (WorkflowActionGroup) -> String,
        fireFailureHook: @Sendable (WorkflowActionGroup, String) async -> Void
    ) async {
        log("PollResultBuilder › freezeVanishedGroups — snapPrev=\(config.snapPrev.count) liveIDs=\(config.liveIDs)", category: .runner)
        for (groupID, group) in config.snapPrev where !config.liveIDs.contains(groupID) {
            log("PollResultBuilder › freezeVanishedGroups — vanished groupID=\(group.id) inCache=\(cache[groupID] != nil)", category: .runner)
            let isUnseen = !seenGroupIDs.contains(groupID)
            if isUnseen { seenGroupIDs.append(groupID) }
            if let existing = cache[groupID], existing.isDimmed, existing.jobs.count >= group.jobs.count {
                log("PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) already cached+dimmed, skipping", category: .runner)
                continue
            }
            if isUnseen && cache[groupID] == nil {
                let scope = scopeFromGroup(group)
                let shouldFire = group.runs.contains { $0.conclusion?.isHookConclusion == true }
                if shouldFire {
                    log("PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) unseen+hookConclusion → fireFailureHook scope=\(scope)", category: .runner)
                    await fireFailureHook(group, scope)
                }
            }
            if group.lastJobCompletedAt == nil {
                cache[groupID] = group.copying(isDimmed: true, settingCompletedAt: config.now)
            } else {
                cache[groupID] = group.copying(isDimmed: true)
            }
        }
    }

    public static func trimGroupCache(_ cache: inout [String: WorkflowActionGroup], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        cache = [String: WorkflowActionGroup](uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    public static func trimSeenGroupIDs(_ ids: inout OrderedSet<String>, limit: Int) {
        guard ids.count > limit else { return }
        let excess = ids.count - limit
        ids.removeSubrange(0..<excess)
    }

    public static func buildGroupDisplay(
        live: [WorkflowActionGroup],
        cache: [String: WorkflowActionGroup]
    ) -> [WorkflowActionGroup] {
        let inProgress = live.filter { $0.groupStatus == .inProgress }
        let loading    = live.filter { $0.groupStatus == .loading }
        let queued     = live.filter { $0.groupStatus == .queued }
        let liveGroupIDs = Set(live.map { $0.id })
        let cached = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        var display: [WorkflowActionGroup] = []
        display.appendUpTo(groupDisplayLimit, from: inProgress)
        display.appendUpTo(groupDisplayLimit, from: loading)
        display.appendUpTo(groupDisplayLimit, from: queued)
        display.appendUpTo(groupDisplayLimit, from: cached) { !liveGroupIDs.contains($0.id) }
        return display
    }
}

// MARK: - Array fill helper

private extension Array {
    mutating func appendUpTo<S>(
        _ limit: Int,
        from source: S,
        where shouldAppend: (S.Element) -> Bool = { _ in true }
    ) where S: Sequence, S.Element == Element {
        guard count < limit else { return }
        for element in source where count < limit && shouldAppend(element) {
            append(element)
        }
    }
}

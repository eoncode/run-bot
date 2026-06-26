// RunnerPoller+PollBridge.swift
// RunnerBarCore
//
// Step 10: Moved to RunnerBarCore as `extension RunnerPoller`.
import Collections
import Foundation
import os

// MARK: - RunnerPoller PollBridge

extension RunnerPoller {

    func buildJobState(
        snapPrev: [Int: ActiveJob],
        snapCache: [Int: ActiveJob]
    ) async -> JobPollResult {
        await PollResultBuilder.buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            fetchJobs: {
                let scopes = await MainActor.run { self.scopeStore.activeScopes }
                var jobs: [ActiveJob] = []
                for scope in scopes {
                    jobs.append(contentsOf: await fetchActiveJobs(for: scope, decoder: self.decoder))
                }
                return jobs
            },
            backfill: { cache in
                await self.backfillSteps(into: &cache)
            }
        )
    }

    func buildGroupState(
        snapPrevGroups: [String: WorkflowActionGroup],
        snapGroupCache: [String: WorkflowActionGroup],
        snapSeenGroupIDs: OrderedSet<String>,
        jobCache: [Int: ActiveJob]
    ) async -> GroupPollResult {
        let deps = GroupStateDeps(
            fetchGroups: { shaKeyedCache in
                let scopes = await MainActor.run { self.scopeStore.activeScopes }
                var groups: [WorkflowActionGroup] = []
                for scope in scopes {
                    let fetched = await self.actionGroupFetcher.fetch(
                        for: scope,
                        cache: shaKeyedCache
                    )
                    groups.append(contentsOf: fetched)
                }
                return groups
            },
            scopeFromGroup: { group in
                self.scopeFromActionGroup(group)
            },
            fireFailureHook: { group, scope in
                await self.fireFailureHook(group, scope)
            },
            enrichJobs: { jobs in
                self.enrichGroupJobs(jobs, jobCache: jobCache)
            }
        )
        return await PollResultBuilder.buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            snapSeenGroupIDs: snapSeenGroupIDs,
            deps: deps
        )
    }

    func backfillSteps(into cache: inout [Int: ActiveJob]) async {
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            guard cached.conclusion != nil,
                  cached.steps.isEmpty || cached.steps.contains(where: { $0.status == .inProgress }),
                  let scope = scopeFromHtmlUrl(cached.htmlUrl),
                  let data = await ghAPI("repos/\(scope)/actions/jobs/\(cacheID)"),
                  let fresh = try? decoder.decode(JobPayload.self, from: data),
                  !fresh.steps.isEmpty
            else { continue }
            cache[cacheID] = await ISO8601DateParser.shared.makeJob(from: fresh, isDimmed: true)
        }
    }

    // MARK: - Group helpers

    nonisolated func scopeFromActionGroup(_ group: WorkflowActionGroup) -> String {
        log("RunnerPoller › scopeFromActionGroup — group.repo='\(group.repo)' groupID=\(group.id)", category: .runner)
        if !group.repo.isEmpty {
            log("RunnerPoller › scopeFromActionGroup — using group.repo='\(group.repo)'", category: .runner)
            return group.repo
        }
        log("RunnerPoller › scopeFromActionGroup — group.repo is empty, trying htmlUrl of first run", category: .runner)
        if let firstRun = group.runs.first,
           let url = firstRun.htmlUrl,
           let scope = scopeFromHtmlUrl(url) {
            log("RunnerPoller › scopeFromActionGroup — derived scope '\(scope)' from htmlUrl '\(url)'", category: .runner)
            return scope
        }
        log("RunnerPoller › scopeFromActionGroup — ⚠️ could not derive scope for groupID=\(group.id)", category: .runner)
        return ""
    }

    nonisolated func enrichGroupJobs(
        _ jobs: [ActiveJob],
        jobCache: [Int: ActiveJob]
    ) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            let cacheHasConclusion = cached.conclusion != nil && job.conclusion == nil
            let cacheHasBetterSteps = !cached.steps.isEmpty
                && (job.steps.isEmpty || job.steps.contains { $0.status == .inProgress })
                && !cached.steps.contains { $0.status == .inProgress }
            guard cacheHasConclusion || cacheHasBetterSteps else { return job }
            return ActiveJob(
                id: job.id,
                name: job.name,
                htmlUrl: job.htmlUrl,
                status: job.status,
                conclusion: cached.conclusion ?? job.conclusion,
                isDimmed: job.isDimmed,
                runnerName: job.runnerName,
                scope: job.scope,
                startedAt: job.startedAt,
                completedAt: cached.completedAt ?? job.completedAt,
                steps: cacheHasBetterSteps ? cached.steps : job.steps
            )
        }
    }
}

// RunnerPollState.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - RunnerStore thin wrappers
// These extensions delegate to PollResultBuilder so RunnerStore.fetch() call
// sites are unchanged while the logic lives in the independently testable builder.

/// Shared ISO-8601 date formatter for this file.
/// ISO8601DateFormatter is expensive to allocate (loads ICU calendars);
/// keeping one file-level instance avoids repeated allocation on every poll cycle.
private let iso8601 = ISO8601DateFormatter()

/// Extension on `RunnerStore` providing poll-cycle helpers that delegate
/// to `PollResultBuilder` for independently testable build logic.
extension RunnerStore {
    /// Builds the current job-poll state from a previous live-jobs snapshot and
    /// the completed-jobs cache, fetching fresh jobs for all active scopes.
    nonisolated func buildJobState(snapPrev: [Int: ActiveJob], snapCache: [Int: ActiveJob]) -> JobPollResult {
        PollResultBuilder.buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            fetchJobs: {
                var jobs: [ActiveJob] = []
                for scope in ScopeStore.shared.scopes {
                    jobs.append(contentsOf: fetchActiveJobs(for: scope))
                }
                return jobs
            },
            backfill: { cache in
                self.backfillSteps(into: &cache)
            }
        )
    }

    /// Builds the current group-poll state from previous group and job snapshots,
    /// fetching fresh groups for all active scopes and enriching jobs from cache.
    nonisolated func buildGroupState(
        snapPrevGroups: [String: WorkflowActionGroup],
        snapGroupCache: [String: WorkflowActionGroup],
        jobCache: [Int: ActiveJob]
    ) -> GroupPollResult {
        PollResultBuilder.buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            fetchGroups: { shaKeyedCache in
                var groups: [WorkflowActionGroup] = []
                for scope in ScopeStore.shared.scopes {
                    groups.append(contentsOf: fetchActionGroups(for: scope, cache: shaKeyedCache))
                }
                return groups
            },
            scopeFromGroup: { group in
                self.scopeFromActionGroup(group)
            },
            fireFailureHook: { group, scope in
                FailureHookRunner.fireIfNeeded(group: group, scope: scope, callsite: "pollResultBuilder")
            },
            enrichJobs: { jobs in
                self.enrichGroupJobs(jobs, jobCache: jobCache)
            }
        )
    }

    // MARK: - Backfill (retains ghAPI access via RunnerStore)

    /// Fills in missing step data for concluded jobs in `cache` by re-fetching
    /// each job from the GitHub API when steps are absent or still in-progress.
    nonisolated func backfillSteps(into cache: inout [Int: ActiveJob]) {
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            guard
                cached.conclusion != nil,
                cached.steps.isEmpty || cached.steps.contains(where: { $0.status == .inProgress }),
                let scope = scopeFromHtmlUrl(cached.htmlUrl),
                let data = ghAPI("repos/\(scope)/actions/jobs/\(cacheID)"),
                let fresh = try? JSONDecoder().decode(JobPayload.self, from: data),
                !fresh.steps.isEmpty
            else { continue }
            cache[cacheID] = makeActiveJob(from: fresh, iso: iso8601, isDimmed: true)
        }
    }

    // MARK: - Group helpers (retain RunnerStore context)

    /// Derives the API scope string ("owner/repo") for a workflow action group.
    /// Uses `group.repo` when non-empty; falls back to parsing `htmlUrl` of the first run.
    nonisolated func scopeFromActionGroup(_ group: WorkflowActionGroup) -> String {
        log("RunnerStore › scopeFromActionGroup — group.repo='\(group.repo)' groupID=\(group.id)")
        if !group.repo.isEmpty {
            log("RunnerStore › scopeFromActionGroup — using group.repo='\(group.repo)'")
            return group.repo
        }
        if let firstRun = group.runs.first, let url = firstRun.htmlUrl {
            log("RunnerStore › scopeFromActionGroup — group.repo empty, trying htmlUrl='\(url)'")
            if let derived = scopeFromHtmlUrl(url) {
                log("RunnerStore › scopeFromActionGroup — derived scope='\(derived)' from htmlUrl")
                return derived
            }
        }
        log("RunnerStore › ⚠️ scopeFromActionGroup — could not derive scope, returning empty string! groupID=\(group.id)")
        return ""
    }

    /// Merges enriched job data from `jobCache` into `jobs`, preferring cached entries
    /// that have a conclusion or more steps than the freshly-fetched job.
    nonisolated func enrichGroupJobs(_ jobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            let cacheHasConclusion = cached.conclusion != nil && job.conclusion == nil
            let cacheHasMoreSteps = cached.steps.count > job.steps.count
            return (cacheHasConclusion || cacheHasMoreSteps) ? cached : job
        }
    }
}

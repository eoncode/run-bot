# Codebase Audit Progress

Tracking file for the principles audit against:
- [Issue #1471](https://github.com/eoncode/runner-bar/issues/1471) + [`project-principles.md`](../architecture/project-principles.md)
- [Issue #1387](https://github.com/eoncode/runner-bar/issues/1387) + [`reach-goal-principles.md`](../principles/reach-goal-principles.md)

Last updated: 2026-06-21

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | File read and fully analysed |
| 🔲 | File not yet read |
| ⏭️ | Skipped — low signal (pure UI layout, design tokens, small model) |

---

## RunnerBar (app target)

### App/
| File | Status | Notes |
|------|--------|-------|
| `AppDelegate.swift` (23 KB) | 🔲 | High priority — likely contains DI wiring + Task usage |
| `AppDelegate+PanelSetup.swift` (14 KB) | 🔲 | High priority |
| `AppDelegate+Navigation.swift` (5.4 KB) | 🔲 | |
| `AppDelegate+Polling.swift` (1.5 KB) | 🔲 | |
| `AppDelegate+StatusItem.swift` (3.2 KB) | 🔲 | |
| `AppDelegate+StoreSetup.swift` (1.5 KB) | 🔲 | |
| `AppDelegate+OAuthCallback.swift` (816 B) | 🔲 | |
| `PopoverLifecycleCoordinator.swift` (12.8 KB) | 🔲 | Medium priority |
| `PanelVisibilityState.swift` (6.8 KB) | 🔲 | |
| `PanelSheetState.swift` (1.6 KB) | 🔲 | |
| `NavState.swift` (1.2 KB) | 🔲 | |

### DesignSystem/
| File | Status | Notes |
|------|--------|-------|
| `DesignTokens.swift` (8 KB) | ⏭️ | Pure UI tokens — no principle violations expected |
| `PanelViewModifiers.swift` (14 KB) | 🔲 | Check for GCD/Task misuse in modifiers |
| `RemovalAlertModifier.swift` (1.9 KB) | ⏭️ | Small modifier |

### GitHub/
| File | Status | Notes |
|------|--------|-------|
| `GitHubHelpers.swift` (9.1 KB) | ✅ | Contains free transport functions `ghAPI`, `ghPost`, `cancelRun`, `fetchActionLogs`, `fetchJobLog` — root of Finding #1 (P7) |
| `GitHubTokenCache.swift` (4.2 KB) | 🔲 | |
| `OAuthService.swift` (15.2 KB) | 🔲 | High priority — auth flow, likely Task/GCD usage |
| `OAuthSecrets.swift` (2.4 KB) | 🔲 | |

### Preferences/
| File | Status | Notes |
|------|--------|-------|
| `AppPreferencesStore.swift` (4.4 KB) | 🔲 | Relates to `AppPreferencesStoreProtocol` used in RunnerStore |
| `NotificationPreferences.swift` (2 KB) | 🔲 | |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `RunnerStore.swift` | ✅ | Finding #7 raw string in `nextPollInterval()` (P5); protocols `AppPreferencesStoreProtocol`/`ScopeStoreProtocol` defined here (P6) |
| `RunnerStore+PollBridge.swift` | ✅ | Finding #2 `ScopeStore.shared` bypass (P7); Finding #13 `.scopes` vs `.activeScopes` mismatch |
| `RunnerLifecycleService.swift` | ✅ | Finding #11 singleton `shared` with no injection seam (P7) |

### Scope/
| File | Status | Notes |
|------|--------|-------|
| `ScopeStore.swift` | 🔲 | **High priority** — needed to verify Finding #2/#13 (`.scopes` vs `.activeScopes`) |
| `ScopeEntry.swift` | ⏭️ | Small model |

### Services/
| File | Status | Notes |
|------|--------|-------|
| `Keychain.swift` (7.4 KB) | ✅ | Finding #12 FIXME(P24) atomicity gap between SecItemUpdate/Add |
| `DefaultRunnerLabelsService.swift` (845 B) | ⏭️ | Small |
| `FailureHookRunner.swift` (1.9 KB) | 🔲 | |
| `FailureHookRunnerAdapters.swift` (1.7 KB) | 🔲 | |
| `LoginItem.swift` (1.2 KB) | ⏭️ | Small |
| `TerminalLauncher.swift` (1 KB) | ⏭️ | Small |

### UseCases/
| File | Status | Notes |
|------|--------|-------|
| `FailureHookRunnerUseCase.swift` (16.3 KB) | 🔲 | Medium priority — largest use case, check P7/P9 |

### Utilities/
| File | Status | Notes |
|------|--------|-------|
| `WindowGrabber.swift` (2.2 KB) | ⏭️ | AppKit window utility |

### Views/Components/
| File | Status | Notes |
|------|--------|-------|
| `WorkflowContextMenuModifier.swift` (7.6 KB) | ✅ | Finding #3 three `Task.detached` fire-and-forget mutations (P9); Finding #48 free function calls (P7) |
| `SystemStatsViewModel.swift` (12.8 KB) | 🔲 | Medium priority — ViewModel with possible GCD/Task issues |
| `SystemStatsView.swift` (9.4 KB) | 🔲 | |
| `DonutStatusView.swift` (5.1 KB) | ⏭️ | Pure rendering view |
| `SparklineView.swift` (3.6 KB) | ⏭️ | Pure rendering view |
| `RingBuffer.swift` (1.2 KB) | ⏭️ | Data structure |

### Views/Main/
| File | Status | Notes |
|------|--------|-------|
| `InlineJobRowsView.swift` (14.6 KB) | 🔲 | Medium priority — contains `JobContextMenuModifier` usage |
| `ActionRowView.swift` (10.5 KB) | 🔲 | |
| `PanelContainerView.swift` (12.9 KB) | 🔲 | |
| `PanelMainView.swift` (9.1 KB) | 🔲 | |
| `RunnerRowViews.swift` (7.1 KB) | 🔲 | |
| `WorkflowActionGroup+Progress.swift` (5.3 KB) | 🔲 | |
| `PanelHeaderView.swift` (2.5 KB) | ⏭️ | Small view |
| `PanelMainView+Subviews.swift` (580 B) | ⏭️ | Small |

### Views/Runner/
| File | Status | Notes |
|------|--------|-------|
| `RunnerViewModel.swift` (2 KB) | ⏭️ | Small |

### Views/Settings/
| File | Status | Notes |
|------|--------|-------|
| `ScopeEditSheet.swift` (26.5 KB) | 🔲 | **Largest settings file** — high priority |
| `AddRunnerSheet.swift` (18.6 KB) | 🔲 | Medium priority |
| `LocalRunnersView.swift` (17.2 KB) | 🔲 | Medium priority |
| `RunnerDetailSheet.swift` (15.7 KB) | 🔲 | Medium priority |
| `AddRunnerSheet+FormFields.swift` (16.2 KB) | 🔲 | |
| `SettingsView.swift` (10.6 KB) | 🔲 | |
| `ScopesView.swift` (7.8 KB) | 🔲 | |
| `SettingsView+Sections.swift` (9.7 KB) | 🔲 | |
| `FailureHookCommandSheet.swift` (10 KB) | 🔲 | |
| `AddScopeSheet.swift` (13.1 KB) | 🔲 | |
| `AddRunnerSheet+TokenSection.swift` (3.5 KB) | 🔲 | |
| `AddRunnerSheet+Validation.swift` (2.3 KB) | ⏭️ | Small |

### Views/Sheets/
| File | Status | Notes |
|------|--------|-------|
| `BranchSelectorSheet.swift` (10.6 KB) | ✅ | Finding #9 `ghAPI` free function call, no transport DI (P7) |
| `RepoSelectorSheet.swift` (6.8 KB) | 🔲 | Check for same free function pattern |

### Views/StepLog/
| File | Status | Notes |
|------|--------|-------|
| `StepLogView.swift` (15.7 KB) | ✅ | Finding #4 `Task.detached` + `ScopeStore.shared` (P9+P7); Finding #5 `DispatchQueue.global` round-trip (P2); Finding #6 raw string status comparisons (P5) |
| `LogCopyButton.swift` (3.8 KB) | ✅ | Finding #5 call site — GCD hop from StepLogView (P2) |

### Root
| File | Status | Notes |
|------|--------|-------|
| `main.swift` (756 B) | 🔲 | Entry point |
| `Exports.swift` (550 B) | ⏭️ | Re-exports only |

---

## RunnerBarCore (core target)

### GitHub/
| File | Status | Notes |
|------|--------|-------|
| `GitHubTransportShim.swift` (9.4 KB) | ✅ | Root of Finding #1 — free functions `ghAPI`/`ghPost`/etc. defined here |
| `GitHubURLSessionTransport.swift` (29.5 KB) | 🔲 | **Highest priority unread file** — transport implementation |
| `GitHubRateLimitHandler.swift` (14.2 KB) | 🔲 | High priority |
| `GitHubResponseDecoder.swift` (5.5 KB) | 🔲 | |
| `GitHubRequestBuilder.swift` (2.3 KB) | 🔲 | |
| `GitHubConstants.swift` (2.8 KB) | ⏭️ | Constants |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `PollResultBuilder.swift` (20.5 KB) | 🔲 | **High priority** — core polling logic |
| `WorkflowActionGroupFetch.swift` (15.4 KB) | 🔲 | **High priority** — fetch logic, likely free function calls |
| `WorkflowActionGroup.swift` (18.1 KB) | 🔲 | High priority |
| `RunnerStatusEnricher.swift` (15.7 KB) | 🔲 | Medium priority |
| `RunnerConfigStore.swift` (14.4 KB) | 🔲 | Medium priority |
| `SaveRunnerEditsUseCase.swift` (11.8 KB) | 🔲 | Medium priority |
| `ActiveJob.swift` (15.4 KB) | 🔲 | Medium priority |
| `JobStatus.swift` (9.7 KB) | 🔲 | Check `JobStatus`/`JobConclusion` enum completeness (relates to Findings #6/#7) |
| `RunnerModel.swift` (13.1 KB) | 🔲 | |
| `RunnerMetrics.swift` (6.5 KB) | 🔲 | |
| `RunnerModelParser.swift` (4.5 KB) | 🔲 | |
| `LocalRunnerIndex.swift` (5 KB) | 🔲 | |
| `RunnerEditDraft.swift` (5.2 KB) | 🔲 | |
| `RunnerConfigStoreProtocol.swift` (1 KB) | ⏭️ | Protocol definition |
| `RunnerLabelsServiceProtocol.swift` (1.2 KB) | ⏭️ | Protocol definition |
| `RunnerStatusEnricherProtocol.swift` (1.5 KB) | ⏭️ | Protocol definition |
| `RunnerProxyStoreProtocol.swift` (811 B) | ⏭️ | Protocol definition |
| `RunnerProxyStoreError.swift` (675 B) | ⏭️ | Small |
| `RunnerProxyConfig.swift` (1.6 KB) | ⏭️ | Small model |
| `RunnerStatus.swift` (2.6 KB) | ⏭️ | Small model |
| `AggregateStatus.swift` (1.8 KB) | ⏭️ | Small model |
| `CommitResult.swift` (417 B) | ⏭️ | Small model |
| `Runner.swift` (5 KB) | 🔲 | |
| `RunnerConfig.swift` (3.3 KB) | ⏭️ | Small model |

### Scope/
| File | Status | Notes |
|------|--------|-------|
| `ScopePreferencesStore.swift` (8.1 KB) | 🔲 | **High priority** — underlying store used by `ScopeStore`, verify `.scopes` vs `.activeScopes` |
| `ScopeEntry.swift` (2.4 KB) | ⏭️ | Small model |
| `GitHubScope.swift` (1.2 KB) | ⏭️ | Small model |
| `FailureHookRunnerDependencies.swift` (1.5 KB) | 🔲 | |

### Services/
| File | Status | Notes |
|------|--------|-------|
| `ProcessRunner.swift` (21.4 KB) | 🔲 | **High priority** — Process management, likely GCD/P2 violations |
| `LogFetcher.swift` (5.3 KB) | 🔲 | Relates to Finding #4/#9 log fetch chain |

### Utilities/
| File | Status | Notes |
|------|--------|-------|
| `AnyJSON.swift` (3.8 KB) | ⏭️ | JSON utility |
| `FormatElapsed.swift` (1.1 KB) | ⏭️ | Formatting utility |
| `GitHubURLHelpers.swift` (1.3 KB) | ⏭️ | URL helpers |
| `ISO8601DateParser.swift` (1.6 KB) | ⏭️ | Parser |
| `Logger.swift` (1.2 KB) | ⏭️ | Logging wrapper |
| `SystemStats.swift` (1.7 KB) | ⏭️ | Small |

---

## Findings Summary (from files read so far)

| # | File | Principle | Tier |
|---|------|-----------|------|
| 1 | `GitHubHelpers.swift` / `GitHubTransportShim.swift` | P7 — DI | 🔴 1 |
| 2 | `RunnerStore+PollBridge.swift` | P7 — DI | 🔴 1 |
| 3 | `WorkflowContextMenuModifier.swift` | P9 + P7 | 🔴 1 |
| 4 | `StepLogView.swift` | P9 + P7 | 🔴 1 |
| 5 | `StepLogView.swift` → `LogCopyButton.swift` | P2 — GCD | 🟠 2 |
| 6 | `StepLogView.swift` | P5 — typed | 🟠 2 |
| 7 | `RunnerStore.swift` | P5 — typed | 🟠 2 |
| 8 | `JobContextMenuModifier` (location TBD) | P7 — DI | 🟠 2 |
| 9 | `BranchSelectorSheet.swift` | P7 — DI | 🟠 2 |
| 10 | `RunnerStore.swift` | P6 — SRP | 🟢 4 |
| 11 | `RunnerLifecycleService.swift` | P7 — DI | 🟢 4 |
| 12 | `Keychain.swift` | P24 — atomicity | 🟢 4 |
| 13 | `RunnerStore+PollBridge.swift` | P5 — consistency | 🟡 3 |

---

## Next Files to Read (Priority Order)

1. `RunnerBarCore/GitHub/GitHubURLSessionTransport.swift` (29.5 KB)
2. `RunnerBarCore/Runner/PollResultBuilder.swift` (20.5 KB)
3. `RunnerBarCore/Runner/WorkflowActionGroupFetch.swift` (15.4 KB)
4. `RunnerBar/GitHub/OAuthService.swift` (15.2 KB)
5. `RunnerBar/Scope/ScopeStore.swift`
6. `RunnerBarCore/Scope/ScopePreferencesStore.swift`
7. `RunnerBarCore/Services/ProcessRunner.swift` (21.4 KB)
8. `RunnerBarCore/Services/LogFetcher.swift`
9. `RunnerBar/App/AppDelegate.swift` (23 KB)
10. `RunnerBarCore/Runner/WorkflowActionGroup.swift` (18.1 KB)

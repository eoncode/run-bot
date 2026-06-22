# TODO — Issue #1513 Part 2: Wire `sharedGitHubTransport` + Cleanup

> Part of [#1513](https://github.com/eoncode/runner-bar/issues/1513) — Tier 1 / Item 1  
> **Requires Part 1 to be merged first.**

---

## Goal

Wire `sharedGitHubTransport` into the app-launch configure closures so the shim
(`ghAPI`, `ghRaw`, `ghAPIPaginated`) routes through the struct, then remove the
now-redundant free-function originals.

---

## Steps

### Step 1 — Wire shim at app launch

- [ ] In `AppDelegate+StoreSetup.swift` (or wherever `configureGHAPI` etc. are called),
  replace the existing closures with:
  ```swift
  configureGHAPI       { await sharedGitHubTransport.apiAsync($0) }
  configureGHRaw       { await sharedGitHubTransport.raw($0) }
  configureGHAPIPaginated { await sharedGitHubTransport.apiPaginated($0, timeout: $1) }
  ```
- [ ] Confirm `configureGHToken` still fires before the above registrations
- [ ] Verify `sharedGitHubTransport.tokenProvider` correctly resolves via `githubToken()`

### Step 2 — Delete original free-function bodies

- [ ] Remove the original `func urlSessionAPIAsync(...)` module-scope body
  (the shim wrapper from Part 1 Step 5 remains until callers are migrated in Items 4 & 8)
- [ ] Remove `func urlSessionAPIPaginated(...)` original body
- [ ] Remove `func urlSessionRaw(...)` original body
- [ ] Remove `func urlSessionPost(...)` original body
- [ ] Remove `func urlSessionPut(...)` original body
- [ ] Remove `func urlSessionDelete(...)` original body
- [ ] Remove `func cancelRun(...)` original free function
- [ ] Remove `func patchRunnerLabels(...)` original free function
- [ ] Remove `func fetchRegistrationToken(...)` original free function
- [ ] Remove `func fetchRemovalToken(...)` original free function
- [ ] Remove `func deleteRunnerByID(...)` original free function

### Step 3 — Remove remaining module globals

- [ ] Delete `private let rateLimitActor = ...` if it is now only used by the struct
  (move to `GitHubTransport.init` default or keep as file-private if still needed by shims)
- [ ] Confirm zero module-level mutable state remains in `GitHubURLSessionTransport.swift`

### Step 4 — Update `GitHubTransportShim.swift`

- [ ] Remove any now-redundant configure call that duplicates the new wiring from Step 1
- [ ] Confirm the typealias family (`GHAPITransport`, `GHRawTransport`, etc.) still compiles
- [ ] Add a `// TODO(Item 4): migrate callers off shim` comment for the next tier

---

## Verification

- [ ] `swift build` passes with zero errors and zero warnings
- [ ] All existing unit tests green
- [ ] Manual smoke-test: app launches, GitHub API calls succeed end-to-end
- [ ] No remaining free functions in `GitHubURLSessionTransport.swift` (run `grep "^public func\|^private func" Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift`)
- [ ] No remaining module globals (`grep "^private let\|^internal let\|^public let" Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift` → only `sharedGitHubTransport` remains)

---

## Branch / PR

- Branch: `feat/1513-github-transport-struct-part2`
- Target: `feat/1513-github-transport-struct-part1` (or `main` if Part 1 already merged)
- Unlocks: Item 4 and Item 8 (inject `GitHubTransportProtocol` in place of shim calls)

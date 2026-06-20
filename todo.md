# PR-A: Transport layer refactor + RateLimitActorProtocol
**Branch:** `fix/pr-a-transport-layer`
**PR:** [#1492](https://github.com/eoncode/runner-bar/pull/1492)
**Closes:** #1477, #1476, #1485

---

## Commit Plan

### Commit 1 — `fix: replace sharedEncoder with per-call local encoder (#1477)` ✅ DONE (`6c0aa3f2`)
**File:** `Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift`
- [x] Remove `private let sharedEncoder = JSONEncoder()` — removed
- [x] Remove the doc comment above it — removed
- [x] Replace `sharedEncoder` with local `JSONEncoder()` in `urlSessionAPIPaginated` encode
- [x] Replace `sharedEncoder` with local `JSONEncoder()` in `patchRunnerLabels` encode

---

### Commit 2 — `refactor: extract RateLimitActorProtocol and inject into urlSessionExecute (#1485)` ✅ DONE (`9c0686e4`)
**Files:**
- `Sources/RunnerBarCore/GitHub/GitHubRateLimitHandler.swift` — protocol added
- `Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift` — defaulted param added
- `Tests/RunnerBarCoreTests/TestSupport/TestDoubles.swift` — `SpyRateLimitActor` added

**Tasks:**
- [x] Extract `RateLimitActorProtocol` with `set(resetAt:)`, `clear()`, `snapshot()`, and `isLimited: Bool`
- [x] Conform `RateLimitActor` to `RateLimitActorProtocol`
- [x] Add defaulted parameter to `urlSessionExecute`: `rateLimiter: some RateLimitActorProtocol = rateLimitActor`
- [x] Replace all direct `rateLimitActor` references inside `urlSessionExecute` body with `rateLimiter`
- [x] Add `SpyRateLimitActor` to `TestDoubles.swift`

---

### Commit 3 — `refactor: delegate urlSessionAPIPaginated to urlSessionExecute (#1476)` ✅ DONE (`c8b9ccd3`)
**File:** `Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift`
- [x] Rewrite `urlSessionAPIPaginated` body to call `urlSessionExecute` per page
- [x] Pass `rateLimiter` param through from `urlSessionAPIPaginated` down to `urlSessionExecute`
- [x] Preserve accumulation loop (`allItems.append(contentsOf: page)`)
- [x] Preserve partial rate-limit return (return partial items on `.rateLimited`)
- [x] Handle 401: `case .httpError(401)` — sets `didFailAuthentication = true` and breaks
- [x] Preserve `didFailPermission` discard on `.permissionDenied`
- [x] Remove the TODO comment referencing the dual code path
- [x] Remove the `Note:` doc comment warning about dual path
- [x] `sharedDecoder` unchanged (thread-safe)

---

### Commit 4 — `test: rate-limit and auth-abort coverage for paginated transport` ✅ DONE (`9c3571d4`)
**Files:** 
- `Tests/RunnerBarCoreTests/GitHubTransportPaginatedTests.swift` (new file)
- `Sources/RunnerBarCore/GitHub/GitHubTransportShim.swift` (`configureGHAPIPaginated` / `ghAPIPaginated`)

Tests added (via `configureGHAPIPaginated` shim — a higher-level seam than the originally planned `SpyRateLimitActor` + `configureGHToken` approach, chosen because `urlSessionExecute` is `private`):
- [x] `paginatedClearsRateLimitOnSuccess` — happy path via shim
- [x] `paginatedReturnsPartialResultsOnRateLimit` — nil partial return via shim
- [x] `paginatedReturnsNilOnAuthFailure401` — nil on auth failure via shim
- [x] `paginatedReturnsNilOnPermissionDenied` — nil on permission denied via shim
- [x] `paginatedReconfigureReplacesTransport` — wiring test

> **Note:** The original plan called for `SpyRateLimitActor`-driven tests via `configureGHToken` injection,
> but since `urlSessionAPIPaginated` accepts `rateLimiter` as a parameter (not a module-level seam),
> tests instead use the higher-level `configureGHAPIPaginated` shim to exercise the contract.

---

## Key Files
| File | Role |
|------|------|
| `Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift` | Main target — all 3 code commits touch this |
| `Sources/RunnerBarCore/GitHub/GitHubRateLimitHandler.swift` | Protocol extraction (commit 2) |
| `Tests/RunnerBarCoreTests/TestSupport/TestDoubles.swift` | `SpyRateLimitActor` (commit 2) |
| `Tests/RunnerBarCoreTests/GitHubTransportPaginatedTests.swift` | Paginated transport tests (commit 4) |

## Progress
- [x] Commit 1 — sharedEncoder fix (`6c0aa3f2`)
- [x] Commit 2 — RateLimitActorProtocol (`9c0686e4`)
- [x] Commit 3 — paginated refactor (`c8b9ccd3`)
- [x] Commit 4 — tests (`9c3571d4`)

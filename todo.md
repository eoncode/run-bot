# PR-A: Transport layer refactor + RateLimitActorProtocol
**Branch:** `fix/pr-a-transport-layer`
**PR:** [#1492](https://github.com/eoncode/runner-bar/pull/1492)
**Closes:** #1477, #1476, #1485

---

## Commit Plan

### Commit 1 — `fix: replace sharedEncoder with per-call local encoder (#1477)` ✅ TODO
**File:** `Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift`
- [ ] Remove `private let sharedEncoder = JSONEncoder()` at line 15
- [ ] Remove the doc comment above it (lines 11-14)
- [ ] Replace `sharedEncoder` at line 200 (`urlSessionAPIPaginated` encode) with `let encoder = JSONEncoder()` + `encoder.encode(...)`
- [ ] Replace `sharedEncoder` at line 348 (`patchRunnerLabels` encode) with `let encoder = JSONEncoder()` + `encoder.encode(...)`

**Why:** Two concurrent paginated calls both calling `sharedEncoder.encode(...)` concurrently is unsafe. `RunnerConfigStore` already uses per-call encoders for this reason.

---

### Commit 2 — `refactor: extract RateLimitActorProtocol and inject into urlSessionExecute (#1485)` ✅ TODO
**Files:**
- `Sources/RunnerBarCore/GitHub/GitHubRateLimitHandler.swift` — add protocol
- `Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift` — add defaulted param
- `Tests/RunnerBarCoreTests/TestSupport/TestDoubles.swift` — add `SpyRateLimitActor`

**Tasks:**
- [ ] Extract `RateLimitActorProtocol` with methods: `set(resetAt:)`, `clear()`, `snapshot()` and property `isLimited: Bool` — add above `RateLimitActor` in `GitHubRateLimitHandler.swift`
- [ ] Conform `RateLimitActor` to `RateLimitActorProtocol`
- [ ] Add defaulted parameter to `urlSessionExecute`: `rateLimiter: some RateLimitActorProtocol = rateLimitActor` — zero call-site breakage
- [ ] Replace all direct `rateLimitActor` references inside `urlSessionExecute` body with `rateLimiter`
- [ ] Add `SpyRateLimitActor` to `TestDoubles.swift` — actor conforming to `RateLimitActorProtocol`, records calls, injectable state

---

### Commit 3 — `refactor: delegate urlSessionAPIPaginated to urlSessionExecute (#1476)` ✅ TODO
**File:** `Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift`
- [ ] Rewrite `urlSessionAPIPaginated` body to call `urlSessionExecute` per page
- [ ] Pass `rateLimiter` param through from `urlSessionAPIPaginated` down to `urlSessionExecute`
- [ ] Preserve accumulation loop (`allItems.append(contentsOf: page)`)
- [ ] Preserve partial rate-limit return (return partial items on `.rateLimited`)
- [ ] Handle 401: `urlSessionExecute` returns `httpError(401)` — inspect explicitly at call site, set `didFailAuthentication = true` and break
- [ ] Preserve `didFailPermission` discard on `.permissionDenied`
- [ ] Remove the TODO comment referencing the dual code path
- [ ] Remove the `Note:` doc comment warning about dual path
- [ ] Update `sharedDecoder` in paginated loop → still OK (decoder is thread-safe, kept as module-level)

**Key constraint:** `urlSessionExecute` has no `.authFailed` case — 401 comes back as `httpError(401)`. Must explicitly check `case .httpError(401)` in the paginated loop.

---

### Commit 4 — `test: rate-limit and auth-abort coverage for paginated transport` ✅ TODO
**File:** `Tests/RunnerBarCoreTests/GitHubTransportShimTests.swift` (or new file)

Tests to add (using `SpyRateLimitActor` + `configureGHToken` for injection):
- [ ] `paginatedReturnsPartialResultsOnRateLimit` — spy returns `.rateLimited`, verify partial items returned
- [ ] `paginatedReturnsNilOnAuthFailure401` — spy returns `httpError(401)`, verify `nil` returned and partial items discarded
- [ ] `paginatedReturnsNilOnPermissionDenied` — spy returns `.permissionDenied`, verify `nil` returned
- [ ] `paginatedClearsRateLimitOnSuccess` — happy path, verify `rateLimiter.clear()` called

> Note: `urlSessionExecute` is `private` — tests drive `urlSessionAPIPaginated` directly via the
> injected `rateLimiter` parameter (added in commit 2/3). Token injection via `configureGHToken`.

---

## Key Files
| File | Role |
|------|------|
| `Sources/RunnerBarCore/GitHub/GitHubURLSessionTransport.swift` | Main target — all 3 code commits touch this |
| `Sources/RunnerBarCore/GitHub/GitHubRateLimitHandler.swift` | Protocol extraction (commit 2) |
| `Tests/RunnerBarCoreTests/TestSupport/TestDoubles.swift` | `SpyRateLimitActor` (commit 2) |
| `Tests/RunnerBarCoreTests/GitHubTransportShimTests.swift` | New tests (commit 4) |

## Progress
- [x] Commit 1 — sharedEncoder fix (`6c0aa3f2`)
- [x] Commit 2 — RateLimitActorProtocol (`9c0686e4`)
- [ ] Commit 3 — paginated refactor
- [ ] Commit 4 — tests

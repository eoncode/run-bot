# TODO — Issue #1513 Part 1: Define Protocol + Create `struct GitHubTransport`

> Part of [#1513](https://github.com/eoncode/runner-bar/issues/1513) — Tier 1 / Item 1  
> Prerequisite for Item 4 and Item 8. Merge Part 1 before starting Part 2.

---

## Goal

Define `GitHubTransportProtocol` and move all free functions + module globals from
`GitHubURLSessionTransport.swift` onto `struct GitHubTransport`.
Backward-compat shim wrappers keep existing call-sites unchanged.

---

## Steps

### Step 1 — Define `GitHubTransportProtocol`

- [ ] Add the protocol to `GitHubURLSessionTransport.swift` (above the struct):
  ```swift
  public protocol GitHubTransportProtocol: Sendable {
      func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data?
      func apiPaginated(_ endpoint: String, timeout: TimeInterval) async -> Data?
      func raw(_ endpoint: String, timeout: TimeInterval) async -> Data?
      func post(_ endpoint: String, body: Data?, timeout: TimeInterval) async -> Data?
      func put(_ endpoint: String, body: Data, timeout: TimeInterval) async -> Data?
      func delete(_ endpoint: String, timeout: TimeInterval) async -> Bool
      func cancelRun(runID: Int, scope: String) async -> Bool
      func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) async -> [String]?
      func fetchRegistrationToken(scope: String) async -> String?
      func fetchRemovalToken(scope: String) async -> String?
      func deleteRunnerByID(scope: String, runnerID: Int) async -> Bool
  }
  ```
- [ ] Confirm `GitHubTransportShim.swift` typealias family still compiles (no rename yet)

### Step 2 — Create `struct GitHubTransport: GitHubTransportProtocol`

- [ ] Declare the struct below the protocol
- [ ] Move `private let sharedDecoder` → stored `let decoder: JSONDecoder` on struct
- [ ] Move `private let sharedEncoder` → stored `let encoder: JSONEncoder` on struct
- [ ] Add `rateLimiter` and `tokenProvider` stored properties
- [ ] Write `public init(decoder:encoder:rateLimiter:tokenProvider:)` with sensible defaults

### Step 3 — Move `urlSessionExecute` → `private func execute` on struct

- [ ] Convert `private func urlSessionExecute(...)` into `private func execute(...)` on the struct
- [ ] Replace all `rateLimitActor` references → `self.rateLimiter`
- [ ] Replace all `githubTokenCore()` calls → `self.tokenProvider()`
- [ ] Replace all `sharedDecoder` / `sharedEncoder` references → `self.decoder` / `self.encoder`
- [ ] Delete the now-unused module-level `sharedDecoder` and `sharedEncoder` globals

### Step 4 — Implement all protocol methods on the struct

- [x] Move `urlSessionAPIAsync` body → `func apiAsync` on struct
- [x] Move `urlSessionAPIPaginated` body → `func apiPaginated` on struct
- [x] Move `urlSessionRaw` body → `func raw` on struct
- [x] Move `urlSessionPost` body → `func post` on struct
- [x] Move `urlSessionPut` body → `func put` on struct
- [x] Move `urlSessionDelete` body → `func delete` on struct
- [x] Move `cancelRun` body → `func cancelRun` on struct
- [x] Move `patchRunnerLabels` body → `func patchRunnerLabels` on struct
- [x] Move `fetchRegistrationToken` body → `func fetchRegistrationToken` on struct
- [x] Move `fetchRemovalToken` body → `func fetchRemovalToken` on struct
- [x] Move `deleteRunnerByID` body → `func deleteRunnerByID` on struct

### Step 5 — Add `internal let sharedGitHubTransport` + backward-compat shims

- [x] Declare `internal let sharedGitHubTransport = GitHubTransport()` (module-level, one instance)
- [x] Keep every existing `public func urlSessionAPIAsync(...)` etc. as a one-liner forwarding to `sharedGitHubTransport`
- [ ] Verify each shim compiles and routes correctly
- [ ] Confirm `ghAPI()`, `ghRaw()`, `ghAPIPaginated()` in `GitHubTransportShim.swift` still resolve (no wiring change yet — that's Part 2 Step 1)

---

## Verification

- [ ] `swift build` passes with zero errors and zero warnings
- [ ] All existing unit tests green
- [ ] No call-site changes required outside this file

---

## Branch / PR

- Branch: `feat/1513-github-transport-struct-part1`
- Target: `main` (or the Tier 1 integration branch)
- Merge **before** starting Part 2

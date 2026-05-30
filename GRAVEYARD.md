# GRAVEYARD — Investigation Log

Branch: `fix/runner-json-bom-and-githuburl-casing`
Goal: `arm64 · macOS` subtitle appears on ALL local runners, not just one.

---

## What we know for certain

- `arm64 · macOS` does **NOT** come from the `.runner` file on disk.
- It comes from the GitHub API — specifically from the runner's labels (e.g. `["self-hosted", "macOS", "arm64"]`) fetched by `RunnerStatusEnricher`.
- `RunnerStatusEnricher` needs a valid `gitHubUrl` from the `.runner` JSON to know which API endpoint to call.

---

## Attempt 1 — BOM strip + CodingKey fix ✅ Partial success

**Hypothesis:** `gitHubUrl` was decoding as `nil` for ALL runners because:
1. The `.runner` file has a UTF-8 BOM (`0xEF 0xBB 0xBF`) that `JSONDecoder` chokes on silently.
2. The `CodingKey` was mapped to `"GitHubUrl"` (PascalCase) but the file contains `"gitHubUrl"` (camelCase).

**What we did:** Stripped BOM from raw `Data` before decoding. Fixed CodingKey to `"gitHubUrl"`.

**Result:** `psw-pwa-repo-runner-1` now shows `arm64 · macOS`. ✅  
`psw-org-runner` still does not. ❌

---

## Current hypothesis — `psw-org-runner` enrichment still failing

`psw-org-runner` is an **org-level runner**. Its `gitHubUrl` likely points to the org (`https://github.com/psw-pwa`) not a repo.

`RunnerStatusEnricher` may only handle repo-scoped URLs and silently skip org-scoped ones — meaning no API call is made for `psw-org-runner`, no labels returned, no subtitle.

**Next step:** Read `RunnerStatusEnricher.swift` (RunnerBarCore) to confirm whether org-scoped `gitHubUrl` values are handled. Fix if not.

---

## What has NOT been touched yet

- `RunnerStatusEnricher.swift` — not read, not changed
- The view layer rendering the subtitle — not confirmed which file
- `Runner.swift` / `RunnerStore.swift` — confirmed not the source of `arm64·macOS`, not changed

---

## Dead ends / wrong turns

- **CPU/MEM regression:** Suspected my commit caused it. Diff proved it did not — nothing in the metrics path was touched. CPU/MEM only shows on actively busy runners; both runners happened to be idle at screenshot time.
- **`.runner` file as source of arm64/macOS:** Incorrectly assumed this twice. Corrected: labels come from GitHub API via enricher, not disk.
- **`RunnerStore` architecture discussion:** Got sidetracked into a refactor discussion about Runner vs Scope separation. Not relevant to the immediate bug.

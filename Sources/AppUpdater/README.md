# AppUpdater

A host-agnostic Swift library target that drives an in-app auto-update flow
for macOS apps distributed outside the Mac App Store. Zero dependency on
RunBotCore or any host code — all host-specific values are injected by the
caller.

## Flow

```
GitHub Releases poll → semver compare (incl. beta.N) → zip download
    → SHA-256 sidecar verification → cache → host state mutation
    → install & relaunch on user confirmation
```

## Quick start

### 1. Conform your state model to `UpdateStateProviding`

```swift
extension MyUpdateState: UpdateStateProviding {}
```

All properties are read-only `{ get }`; mutations go through named methods
(`setDownloadComplete`, `setUpdateFailed`, etc.) so no caller can write
`updateZipURL` without also setting the paired version.

### 2. Construct the updater

```swift
let updater = AppUpdater(
    repo: "your-org/your-repo",
    currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
    assetName: { _ in "YourApp.zip" },               // SHA-256 sidecar expected at "<assetName>.sha256"
    schedulerIdentifier: "com.your-org.update-check" // also scopes UserDefaults keys
)
```

### 3. Drive it from your app delegate

```swift
updater.rehydrateCachedUpdateIfNewer(state: myState) // offline-ready, before any network
await updater.checkAndHandle(state: myState)          // channel-aware check + download/cache
updater.scheduleBackgroundCheck(state: myState)       // daily background re-check

// From the "Install & Relaunch" button:
await updater.installAndRelaunch(state: myState)
```

## Distribution assumptions

- The release archive carries exactly one `.app` at its root.
- Each release attaches a `<assetName>.sha256` sidecar. A missing sidecar is a hard failure.
- On any download/install failure the host’s failure flag is set so the app can surface a
  browser-download fallback. This is a designed recovery path, not a silent failure.

## Persisted state

Two `UserDefaults` keys scoped by `schedulerIdentifier` survive a relaunch so a
downloaded-but-not-yet-installed update is offered again on next launch:

- `<domain>.cachedUpdateZipPath`
- `<domain>.cachedUpdateVersion`

The verified zip is cached at `~/Library/Caches/<schedulerIdentifier>/update-<version>.zip`.

## Logging

Messages appear in Console.app under subsystem `io.github.appupdater`, category `AppUpdater`.
`.debug` calls are elided at zero cost in release builds when no one is streaming.

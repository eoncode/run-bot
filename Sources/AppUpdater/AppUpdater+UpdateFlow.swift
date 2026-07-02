// AppUpdater+UpdateFlow.swift
// AppUpdater
import Foundation

// MARK: - Update flow entry points

/// Update-flow entry points: check and handle available releases.
extension AppUpdater {

    // MARK: - Convenience entry points

    /// Runs a full update check and handles the result.
    ///
    /// On `.updateAvailable` the release is downloaded/cached via `handle`.
    /// `.upToDate` and `.failed` are no-ops here (the background scheduler owns
    /// the stale-row-clearing policy) — this mirrors a launch-time check that
    /// must never clear a ready-to-install update after a transient failure.
    public func checkAndHandle(state: any UpdateStateProviding) async {
        let beta = betaChannelProvider()
        switch await checkForUpdate(betaChannel: beta) {
        case .updateAvailable(let release):
            appUpdaterLogger.debug("update available: \(release.tagName, privacy: .public) (beta=\(beta, privacy: .public))")
            await handle(release, state: state)
        case .upToDate:
            appUpdaterLogger.debug("no update available (beta=\(beta, privacy: .public))")
        case .failed(let error):
            appUpdaterLogger.debug("update check failed: \(String(describing: error), privacy: .public) (beta=\(beta, privacy: .public))")
        }
    }

    /// Runs a channel-aware update check via the injected `ReleaseProvider`.
    ///
    /// Fetches via `provider.fetchLatestRelease` and performs the `isNewer`
    /// comparison here in `AppUpdater`. `UpdateChecker.checkForUpdate` remains
    /// `public` as an escape hatch for callers who need a raw `UpdateCheckResult`
    /// without constructing an `AppUpdater` instance.
    ///
    /// Intentionally `internal` — `checkAndHandle` is the designed public entry
    /// point for host apps.
    func checkForUpdate(betaChannel: Bool) async -> UpdateCheckResult {
        guard !currentVersion.isEmpty else {
            return .failed(UpdateCheckError.missingVersionKey)
        }
        guard let latest = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        ) else {
            return .failed(UpdateCheckError.noReleasesFound)
        }
        guard UpdateChecker.isNewer(latest.tagName, than: currentVersion) else {
            return .upToDate
        }
        return .updateAvailable(release: latest)
    }

    // MARK: - Handle

    /// Responds to a newly discovered available release.
    ///
    /// 1. If a matching cached zip already exists for this version, moves
    ///    directly to `.ready` without re-downloading.
    /// 2. If the release has no matching zip asset **or** no checksum sidecar
    ///    URL, logs a warning and returns — no phase change. The host retains
    ///    whatever state it had (typically `.idle`).
    /// 3. Otherwise moves to `.available`, then immediately starts a background
    ///    download that will advance through `.downloading` → `.ready`.
    public func handle(_ release: AvailableRelease, state: any UpdateStateProviding) async {

        // ── 1. Already cached? ───────────────────────────────────────────────
        let cachedVersion = defaults.string(forKey: keys.cachedUpdateVersion)
        let cachedPath = defaults.string(forKey: keys.cachedUpdateZipPath)
        if let cachedVersion, cachedVersion == release.tagName, let path = cachedPath {
            if FileManager.default.fileExists(atPath: path) {
                state.apply(.ready(version: cachedVersion, zipURL: URL(fileURLWithPath: path)))
                return
            }
            clearCachedDefaults()
        }

        // ── 2. Asset or checksum sidecar absent? ─────────────────────────────
        // Log a warning and return without changing phase. The host stays in
        // whatever state it was in (typically .idle). No curl-install fallback
        // is shown — the release was simply published without the expected asset.
        let wantedAsset = assetName(release.tagName)
        guard let asset = release.assets.first(where: { $0.name == wantedAsset }) else {
            appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no asset named \(wantedAsset, privacy: .public) — skipping download")
            return
        }
        guard release.checksumURL != nil else {
            appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no checksum sidecar — skipping download")
            return
        }

        // ── 3. In-flight guard ───────────────────────────────────────────────
        guard !isDownloading else { return }
        isDownloading = true

        // Signal that a newer version is available before the download begins.
        state.apply(.available(version: release.tagName))

        // ── 3b. Wipe cached defaults then start download ─────────────────────
        // clearCachedDefaults() MUST run before the download Task is spawned.
        // See the original ordering rationale: UserDefaults must not contain a
        // stale path that points at a file never fully downloaded. Running
        // clearCachedDefaults() first ensures a crash here leaves defaults clean.
        clearCachedDefaults()

        let downloadURL = asset.browserDownloadURL
        let checksumURL = release.checksumURL
        let tagName = release.tagName

        // Fire-and-forget — see downloadUpdate doc comment for full rationale.
        Task(name: "AppUpdater.download") {
            await self.downloadUpdate(from: downloadURL, checksumURL: checksumURL, version: tagName, state: state)
        }
    }
}

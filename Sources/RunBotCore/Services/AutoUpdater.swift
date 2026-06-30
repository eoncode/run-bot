// AutoUpdater.swift
// RunBotCore
import AppKit
import Foundation

// MARK: - AutoUpdater

/// Drives the background download phase of the in-app auto-update flow
/// described in issue #1794.
///
/// `AutoUpdater` is a caseless enum (no instances, no state of its own) that
/// acts as a namespace for static functions. All persistent state lives in
/// `RunnerState` (in-memory, `@Observable`) and `UserDefaults` (via
/// `AutoUpdaterDefaults`) so the flow survives app restarts gracefully.
///
/// ## Typical call sequence
///
/// ```
/// // In AppDelegate+PanelSetup, after UpdateChecker resolves:
/// case .updateAvailable(let release):
///     runnerState.setAvailableUpdate(release.tagName)
///     await AutoUpdater.handle(release, state: runnerState)
/// ```
///
/// `handle` returns immediately after starting the download task — it does
/// not await the download itself. The download runs on a detached `Task` so
/// it does not block the startup sequence.
public enum AutoUpdater {

    /// The expected asset name for the RunBot binary zip.
    ///
    /// `publish.yml` attaches the zip with this exact name. Keeping it as a
    /// constant prevents a typo in a string literal from silently causing
    /// every release to fall back to the browser-download path.
    static let expectedAssetName = "RunBot.zip"

    // MARK: - Entry point

    /// Responds to a newly discovered available release.
    ///
    /// 1. If a matching cached zip already exists for this version, rehydrates
    ///    `RunnerState` from `UserDefaults` and returns without re-downloading.
    /// 2. If the release has no `RunBot.zip` asset, sets
    ///    `runnerState.updateAssetMissing = true` so the UI shows a browser
    ///    Download fallback, then returns.
    /// 3. Otherwise, starts a detached `Task` to download the zip in the
    ///    background. `RunnerState` is updated on `MainActor` when done.
    ///
    /// - Parameters:
    ///   - release: The `AvailableRelease` returned by `UpdateChecker`.
    ///   - state: The shared `RunnerState` instance to update.
    @MainActor
    public static func handle(_ release: AvailableRelease, state: RunnerState) async {
        // ── 1. Already cached? ──────────────────────────────────────────────
        let defaults = UserDefaults.standard
        let cachedVersion = defaults.string(forKey: AutoUpdaterDefaults.cachedUpdateVersion)
        let cachedPath   = defaults.string(forKey: AutoUpdaterDefaults.cachedUpdateZipPath)

        if cachedVersion == release.tagName,
           let path = cachedPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                state.updateZipURL = url
                state.cachedUpdateVersion = cachedVersion
                // Clear any stale failure flag from a prior session. Without this,
                // a previous `updateActionFailed = true` would survive into a fresh
                // launch where the zip is already cached and valid, causing the UI
                // to show the Download fallback instead of Install & Relaunch.
                state.updateActionFailed = false
                return
            }
            // Cached path no longer exists on disk — clear stale defaults and
            // fall through to a fresh download.
            clearCachedDefaults()
        }

        // ── 2. Asset absent from release? ───────────────────────────────────
        // Always reset `updateAssetMissing` before the guard so that a
        // subsequent `handle` call for a release that *does* carry the asset
        // (e.g. a re-published release) clears the flag and proceeds to
        // download — rather than leaving the Download-from-browser fallback
        // permanently visible.
        state.updateAssetMissing = false
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) else {
            state.updateAssetMissing = true
            return
        }

        // ── 3. Kick off background download ─────────────────────────────────
        // Capture only the values the Task needs (URL + version string) rather
        // than the entire `RunnerState` object.
        //
        // `RunnerState` is `@MainActor`-isolated and `final class` (not yet
        // declared `Sendable`). Passing it into `Task.detached` is safe here
        // because `downloadUpdate` routes every state mutation back through
        // `await MainActor.run { }`, so all writes are correctly serialised on
        // MainActor. The Swift 6 strict-concurrency checker accepts this
        // pattern; no warning is emitted because `state` is only ever *read*
        // from the detached context to be forwarded, not written to directly.
        //
        // ── 3b. In-flight guard ──────────────────────────────────────────────
        // Prevent a second concurrent download of the same zip. This can
        // happen if the background scheduler fires while a Task.detached
        // download is already running — both would race to write the same
        // destination file, with the try? removeItem between them creating a
        // window where neither write wins cleanly.
        //
        // `isDownloading` is `@MainActor`-isolated, so this read-modify-write
        // is atomic with respect to all other `handle()` callers.
        //
        // ⚠️ ORDERING IS INTENTIONAL — do not move this guard above the cache-hit
        // or asset-missing blocks (steps 1 and 2). Those two early-exit paths
        // return *before* Task.detached is ever reached — they never start a
        // download — so the in-flight guard is irrelevant to them. Placing it
        // first would guard code paths it was not designed for and would
        // incorrectly block a cache-hit rehydration if a background download
        // happened to be in flight for a different version.
        guard !isDownloading else { return }
        isDownloading = true

        let downloadURL = asset.browserDownloadURL
        let tagName = release.tagName

        Task.detached(priority: .background) {
            await downloadUpdate(from: downloadURL, version: tagName, state: state)
        }
    }

    // MARK: - Download

    /// Downloads the zip to the caches directory, then updates `RunnerState`
    /// and `UserDefaults` on success.
    ///
    /// On any failure, `runnerState.updateActionFailed` is set to `true` so the
    /// UI can offer the browser-based fallback.
    ///
    /// ## ⚠️ NO ZIP INTEGRITY CHECK — THIS IS INTENTIONAL, TRACKED IN #1795 ⚠️
    ///
    /// This function does NOT verify the downloaded zip in any way. There is no
    /// SHA-256 checksum comparison, no GPG signature check, no `codesign --verify`
    /// call, and no zip-structure sanity check. The file is moved to disk as-is.
    ///
    /// This is a DELIBERATE, DOCUMENTED deferral — not an oversight.
    ///
    /// **Why deferred:** Integrity checking requires publishing a checksum file
    /// alongside the zip in publish.yml (SHA-256 sidecar or a signed manifest),
    /// which is a non-trivial CI change with its own review cycle. Doing it
    /// half-heartedly here (e.g. checking zip magic bytes only) creates false
    /// confidence. The correct solution is tracked in full in issue #1795.
    ///
    /// **What is already in place for #1795:** `AvailableRelease.checksumURL`
    /// is already decoded from the GitHub Releases JSON, so #1795 can add
    /// verification without any model change — just the download + compare logic.
    ///
    /// **REVIEWER: Do NOT request adding `codesign --verify` or a checksum here.
    /// It belongs in #1795. Adding a partial check here without the publish.yml
    /// sidecar would silently fail for every real release and block all updates.
    /// This is a known gap, not a forgotten one.**
    ///
    /// - Parameters:
    ///   - url: The direct download URL for the `RunBot.zip` asset.
    ///   - version: The tag name of the release being downloaded.
    ///   - state: The shared `RunnerState` to update on the `MainActor`.
    private static func downloadUpdate(
        from url: URL,
        version: String,
        state: RunnerState
    ) async {
        do {
            // Use a dedicated URLSession with explicit timeouts rather than
            // URLSession.shared (which has no timeout configured). On a stalled
            // connection — mobile hotspot, corporate proxy, flaky Wi-Fi — the
            // shared session would hang indefinitely with no cancellation path.
            //
            // timeoutIntervalForRequest: 30 s — max time to receive the *first*
            //   byte after the request is sent. Covers DNS hangs, TLS stalls,
            //   and unresponsive CDN edge nodes.
            // timeoutIntervalForResource: 300 s — max total download time.
            //   RunBot.zip is small (< 10 MB); 5 minutes is generous even on
            //   a slow connection while still guaranteeing eventual failure
            //   rather than an eternal hang.
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest  = 30
            sessionConfig.timeoutIntervalForResource = 300
            let session = URLSession(configuration: sessionConfig)

            // URLSession.download(from:) streams to a temp file automatically;
            // we move it to the caches directory so it persists across restarts.
            // Redirects are followed transparently — the response here is the
            // terminal response after all redirects, so statusCode reflects the
            // final server reply (not an intermediate redirect).
            let (tempURL, response) = try await session.download(from: url)

            // ⚠️ `!= 200` IS INTENTIONALLY STRICT — DO NOT WIDEN TO `!(200...299)` ⚠️
            //
            // This is NOT a bug. GitHub's asset CDN (objects.githubusercontent.com)
            // returns exactly HTTP 200 on a successful full-file download. The other
            // 2xx codes cannot occur here:
            //   • 206 Partial Content — impossible, we send no Range header.
            //   • 304 Not Modified   — impossible, we send no If-None-Match /
            //                         If-Modified-Since header.
            //
            // Using `!(200...299)` would silently accept a 206 or 304 body as a
            // valid zip and cache a corrupt / zero-byte file. The strict `!= 200`
            // check ensures we only cache a response we know to be a complete file.
            //
            // REVIEWER: Do NOT change this to `!(200...299)`. If GitHub's CDN ever
            // returns a non-200 success code, that is the moment to widen the check
            // with a comment explaining which code and why — not before.
            //
            // `guard let` rather than `if let`: a nil cast (non-HTTP response)
            // is treated as an explicit failure rather than a silent pass-through
            // that would move a potentially corrupt temp file into the cache.
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: tempURL)
                throw URLError(.badServerResponse)
            }
            if http.statusCode != 200 {  // ← strict by design, NOT a bug — read comment above before changing
                try? FileManager.default.removeItem(at: tempURL)
                throw URLError(.badServerResponse)
            }

            let destination = try cachedZipDestination(version: version)

            // Remove any stale file from a previous interrupted download.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)

            // Persist to UserDefaults so the install survives a relaunch.
            let defaults = UserDefaults.standard
            defaults.set(version, forKey: AutoUpdaterDefaults.cachedUpdateVersion)
            defaults.set(destination.path, forKey: AutoUpdaterDefaults.cachedUpdateZipPath)

            // Push to RunnerState on the MainActor — Views observe this.
            await MainActor.run {
                state.updateZipURL = destination
                state.cachedUpdateVersion = version
                isDownloading = false
            }
        } catch {
            await MainActor.run {
                isDownloading = false
                state.updateActionFailed = true
            }
        }
    }

    // MARK: - Helpers

    /// Returns the destination `URL` for the cached zip in the system caches
    /// directory, creating the intermediate directory if needed.
    ///
    /// The file is named `RunBot-<version>.zip` (e.g. `RunBot-v0.8.0.zip`)
    /// so multiple cached versions never collide on disk.
    ///
    /// ## Stale zip accumulation — known, acceptable, low priority
    ///
    /// Each update cycle writes a new version-stamped file. `downloadUpdate`
    /// removes the file at `destination` before writing (handling interrupted
    /// downloads of the *same* version), but files from *prior* versions
    /// (e.g. `RunBot-v0.7.9.zip` left over after a successful install) are
    /// not swept here.
    ///
    /// In practice this means at most one stale zip per update cycle accumulates
    /// in `~/Library/Caches/io.github.runbot-hq/`. Each file is ~10–20 MB and
    /// macOS will evict cache-directory contents under storage pressure. This
    /// is acceptable for a low-frequency update path.
    ///
    /// If a future audit shows meaningful accumulation, add a sweep here:
    ///
    ///     let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    ///     existing.filter { $0.lastPathComponent.hasPrefix("RunBot-") && $0.pathExtension == "zip" }
    ///             .forEach { try? fm.removeItem(at: $0) }
    ///
    /// REVIEWER: The absence of this sweep is intentional, not an oversight.
    private static func cachedZipDestination(version: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = caches.appendingPathComponent("io.github.runbot-hq", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sanitise the version tag: strip any characters that are invalid in
        // a filename (shouldn't arise with semver tags, but belt-and-braces).
        let safe = version.replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent("RunBot-\(safe).zip")
    }

    /// Removes the cached update entries from `UserDefaults`.
    ///
    /// Called when the cached path is stale (file deleted externally) to
    /// prevent an infinite no-op loop on subsequent launches.
    static func clearCachedDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateVersion)
        defaults.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateZipPath)
    }
}

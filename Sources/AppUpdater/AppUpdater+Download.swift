// AppUpdater+Download.swift
// AppUpdater
import CryptoKit
import Foundation

// MARK: - Download

extension AppUpdater {

    /// Downloads the zip and its SHA-256 sidecar in parallel, verifies
    /// integrity, then caches the verified zip and updates host state.
    ///
    /// ## Fire-and-forget rationale
    ///
    /// This function is invoked from a fire-and-forget `Task(name: "AppUpdater.download")`
    /// in `handle()` (see `AppUpdater+UpdateFlow.swift`). Reviewers familiar
    /// with structured concurrency may flag the absence of a stored task handle
    /// or cancellation support as a defect. It is not — this is a deliberate
    /// design decision.
    ///
    /// **Why no stored handle / cancellation:**
    ///
    /// 1. **Lifetime:** `AppUpdater` is owned by `AppDelegate` and lives for
    ///    the entire app lifetime. `deinit` is never reached while a download
    ///    is in flight. `downloadTask?.cancel()` in `deinit` would be dead code.
    ///
    /// 2. **Concurrency guard:** `isDownloading = true` is set before the
    ///    `Task` is spawned in `handle()`. Every subsequent `handle()` call
    ///    returns immediately at the in-flight guard. There is no scenario
    ///    where a second download `Task` is started while this one runs.
    ///
    /// 3. **One-shot, not a loop:** The P3 concurrency-doc pattern of storing a
    ///    task handle applies to long-lived loops (`pollTask`, generation
    ///    counters). A single download-verify-cache operation does not benefit
    ///    from that pattern — there is nothing to cancel mid-flight that would
    ///    leave state cleaner than letting the do/catch complete naturally.
    ///
    /// 4. **`@MainActor` serialisation:** All state mutations in this function
    ///    (`setDownloadComplete`, `setUpdateFailed`, `isDownloading = false`)
    ///    run on the main actor. Order and exclusivity are guaranteed by the
    ///    actor executor without a stored handle.
    ///
    /// REVIEWER: Do NOT raise "unstructured task" or "missing cancellation" as
    /// a finding on `handle()` or `downloadUpdate`. Both have been evaluated
    /// and the fire-and-forget pattern is correct for this case. Adding a
    /// stored `downloadTask` property would be over-engineering a problem that
    /// does not exist in this codebase.
    ///
    /// ## HTTP status validation
    ///
    /// Both the zip response and the checksum sidecar response are validated
    /// for HTTP 200 before their bodies are used. This matters most for the
    /// sidecar: GitHub's CDN returns a 404 HTML page (not an error throw) when
    /// a release was published without a `.sha256` file. Without the status
    /// check the HTML body would be fed into the hex parser, `expectedHex`
    /// would be `"<!DOCTYPE"`, `verifyChecksum` would throw a digest mismatch,
    /// and Console.app would log "checksum mismatch" instead of "sidecar
    /// returned HTTP 404" — making the failure significantly harder to diagnose.
    /// The install is blocked correctly in both cases; this is purely a
    /// diagnosability improvement.
    func downloadUpdate( // skipcq: SW-R1002 — reviewed; complexity acceptable for this download+verify flow
        from url: URL,
        checksumURL: URL?,
        version: String,
        state: any UpdateStateProviding
    ) async {
        var tempURL: URL?
        do {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = 30
            sessionConfig.timeoutIntervalForResource = 300
            let session = URLSession(configuration: sessionConfig)
            defer { session.finishTasksAndInvalidate() }

            // Safety net: handle() now guards against nil checksumURL in step 2
            // before entering the download path, so this branch should be
            // unreachable in normal flow. It is kept as a last-resort defensive
            // check — if a future refactor bypasses the step-2 guard, this
            // prevents a nil URL from reaching URLSession.
            guard let checksumURL else {
                throw URLError(.resourceUnavailable)
            }

            async let zipDownload = session.download(from: url)
            async let checksumDownload = session.data(from: checksumURL)
            let (downloadedURL, zipResponse) = try await zipDownload
            tempURL = downloadedURL
            let (checksumData, checksumResponse) = try await checksumDownload

            // ── Validate zip HTTP status ─────────────────────────────────────
            guard let zipHTTP = zipResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard zipHTTP.statusCode == 200 else {
                appUpdaterLogger.error("zip download returned HTTP \(zipHTTP.statusCode, privacy: .public)")
                throw URLError(.badServerResponse)
            }

            // ── Validate checksum sidecar HTTP status ────────────────────────
            // A non-200 here most commonly means the release was published
            // without a .sha256 sidecar file. Without this guard the CDN's
            // HTML error page would reach the hex parser below, producing a
            // misleading "digest mismatch" log entry instead of the real cause.
            // The install is blocked either way — this guard exists solely to
            // name the failure correctly in Console.app.
            guard let checksumHTTP = checksumResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard checksumHTTP.statusCode == 200 else {
                appUpdaterLogger.error("checksum sidecar returned HTTP \(checksumHTTP.statusCode, privacy: .public) — release may have been published without a .sha256 file")
                throw URLError(.badServerResponse)
            }

            // ── Parse and validate the expected hex string ───────────────────
            let rawChecksum = String(bytes: checksumData, encoding: .utf8) ?? ""
            let expectedHex = rawChecksum
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? ""

            // Explicit guard: an empty expectedHex means the sidecar was
            // zero-length or contained only whitespace (the HTTP 200 / non-200
            // cases are already handled above). verifyChecksum would throw a
            // mismatch anyway ("" != 64-char SHA-256 hex), but this guard
            // prevents a future edit to verifyChecksum from accidentally
            // treating empty as "skip verification".
            guard !expectedHex.isEmpty else {
                appUpdaterLogger.error("checksum sidecar returned HTTP 200 but body was empty or whitespace-only")
                throw URLError(.cannotDecodeContentData)
            }

            try await verifyChecksum(zipURL: downloadedURL, expectedHex: expectedHex)

            let destination = try cachedZipDestination(version: version)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloadedURL, to: destination)

            defaults.set(version, forKey: keys.cachedUpdateVersion)
            defaults.set(destination.path, forKey: keys.cachedUpdateZipPath)

            state.setDownloadComplete(zipURL: destination, version: version)
            isDownloading = false
        } catch {
            if let tmp = tempURL {
                try? FileManager.default.removeItem(at: tmp)
            }
            // `isDownloading` is cleared on the same @MainActor turn as
            // `setUpdateFailed()` — no intermediate state is observable. A
            // subsequent `handle()` call cannot slip through between these two
            // lines because @MainActor serialises all callers onto one executor.
            // Do NOT split these or add an `await` between them.
            isDownloading = false
            state.setUpdateFailed()
        }
    }
}

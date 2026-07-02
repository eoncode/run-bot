// AppUpdater+Download.swift
// AppUpdater
import CryptoKit
import Foundation

// MARK: - Download

/// Download, checksum verification, and local cache management for AppUpdater.
extension AppUpdater {

    /// Downloads the zip and its SHA-256 sidecar in parallel, verifies
    /// integrity, then caches the verified zip and advances host state.
    ///
    /// State transitions driven by this function:
    ///   `.available` → `.downloading` (immediately on entry)
    ///   `.downloading` → `.ready`     (on checksum-verified success)
    ///   `.downloading` → `.failed`    (on any error)
    ///
    /// ## Fire-and-forget rationale
    ///
    /// This function is invoked from a fire-and-forget `Task(name: "AppUpdater.download")`
    /// in `handle()`. See the full rationale in the original doc comment — the
    /// summary is: AppUpdater is process-lifetime, `isDownloading` prevents
    /// concurrent downloads, and `@MainActor` serialises all state mutations.
    func downloadUpdate( // skipcq: SW-R1002 — reviewed; complexity acceptable for this download+verify flow
        from url: URL,
        checksumURL: URL?,
        version: String,
        state: any UpdateStateProviding
    ) async {
        // Signal that the download is actively in progress.
        state.apply(.downloading(version: version))

        var tempURL: URL?
        do {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = 30
            sessionConfig.timeoutIntervalForResource = 300
            let session = URLSession(configuration: sessionConfig)
            defer { session.finishTasksAndInvalidate() }

            // Safety net: handle() guards against nil checksumURL before
            // entering the download path. This is a last-resort defensive check.
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

            isDownloading = false
            state.apply(.ready(version: version, zipURL: destination))
        } catch {
            if let tmp = tempURL {
                try? FileManager.default.removeItem(at: tmp)
            }
            isDownloading = false
            state.apply(.failed(version: version))
        }
    }
}

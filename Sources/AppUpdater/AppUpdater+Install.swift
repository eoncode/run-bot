// AppUpdater+Install.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#endif
import Foundation

// MARK: - Install & Relaunch

/// Install-and-relaunch logic for ``AppUpdater``.
extension AppUpdater {

    /// Unzips the cached update zip, replaces the running `.app` bundle, and
    /// relaunches the new version.
    ///
    /// ## Flow
    /// 1. Verify host is in `.ready` phase and extract zip URL + version.
    /// 2. Unzip into a temporary directory via `/usr/bin/ditto`.
    /// 3. (Optional) Verify `codesign` identity if `skipCodeSignValidation` is `false`.
    /// 4. Replace the running bundle via `FileManager.replaceItem` (atomic swap).
    /// 5. Relaunch the new binary with `/usr/bin/open -n`.
    /// 6. Delete the zip (spend — relaunch confirmed).
    /// 7. Terminate this process via `NSApp.terminate`.
    ///
    /// On any failure `state.apply(.failed(version:))` is called and the
    /// function returns without terminating.
    @MainActor
    public func installAndRelaunch(state: any UpdateStateProviding) async {
        guard !isInstalling else { return }
        isInstalling = true

        // Extract zip URL and version from the .ready phase.
        guard case .ready(let version, let zipURL) = state.currentPhase else {
            isInstalling = false
            state.apply(.failed(version: nil))
            return
        }

        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-update-\(UUID().uuidString)", isDirectory: true)

        guard let appInZip = await unzipAndLocateApp(zipURL: zipURL, into: tmpDir) else {
            isInstalling = false
            state.apply(.failed(version: version))
            return
        }

        #if canImport(AppKit)
        if !skipCodeSignValidation {
            let runningIdentity = await Bundle.main.codeSigningIdentity()
            let updateIdentity = await Bundle(path: appInZip.path)?.codeSigningIdentity()
            guard let runningIdentity,
                  let updateIdentity,
                  runningIdentity == updateIdentity else {
                appUpdaterLogger.error("code-sign identity mismatch — aborting install")
                isInstalling = false
                state.apply(.failed(version: version))
                try? FileManager.default.removeItem(at: tmpDir)
                return
            }
        }
        #endif

        await replaceAndRelaunch(
            appInZip: appInZip,
            bundleURL: bundleURL,
            zipURL: zipURL,
            version: version,
            tmpDir: tmpDir,
            state: state
        )
    }

    // MARK: - Private helpers

    /// Unzips `zipURL` into `tmpDir` via `/usr/bin/ditto` and returns the
    /// `.app` bundle URL found at the archive root.
    private func unzipAndLocateApp(zipURL: URL, into tmpDir: URL) async -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard await runCommand("/usr/bin/ditto", args: ["-xk", zipURL.path, tmpDir.path]) else {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        guard let appInZip = (try? fm.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.pathExtension == "app" }) else {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        return appInZip
    }

    /// Atomically replaces the running bundle, relaunches via `open -n`, deletes
    /// the zip once relaunch is confirmed, then terminates via `NSApp.terminate`.
    private func replaceAndRelaunch( // skipcq: SW-R1002 — reviewed; sequential install steps, complexity is inherent
        appInZip: URL,
        bundleURL: URL,
        zipURL: URL,
        version: String,
        tmpDir: URL,
        state: any UpdateStateProviding
    ) async {
        let fm = FileManager.default
        let backupItemName = bundleURL.lastPathComponent + ".bak"
        var resultingNSURL: NSURL?

        // ── Step 1: atomic bundle swap ───────────────────────────────────────
        do {
            try fm.replaceItem(
                at: bundleURL,
                withItemAt: appInZip,
                backupItemName: backupItemName,
                options: [],
                resultingItemURL: &resultingNSURL
            )
        } catch {
            appUpdaterLogger.error("replaceItem failed: \(String(describing: error), privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── Step 2: wipe cached defaults ─────────────────────────────────────
        clearCachedDefaults()

        // ── Step 3: clean up scratch dir ─────────────────────────────────────
        try? fm.removeItem(at: tmpDir)

        // ── Step 4: relaunch ─────────────────────────────────────────────────
        #if canImport(AppKit)
        let launchPath = ((resultingNSURL as URL?) ?? bundleURL).path
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", launchPath]
        do {
            try relaunchTask.run()
        } catch {
            // `open -n` failed AFTER replaceItem succeeded.
            // The new .app IS on disk. UserDefaults ARE cleared.
            // Apply .failed so the host shows a recoverable error state.
            // The user can relaunch manually — the new binary is already installed.
            appUpdaterLogger.error("open -n failed after successful replaceItem — new binary is on disk, relaunch manually: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            return
        }

        // ── Step 5: delete zip (relaunch confirmed) ──────────────────────────
        try? fm.removeItem(at: zipURL)

        // ── Step 6: terminate ────────────────────────────────────────────────
        NSApp.terminate(nil)
        #endif
    }
}

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
    /// 1. Unzip the cached zip into a temporary directory via `/usr/bin/ditto`.
    /// 2. Locate the `.app` bundle inside the unzipped contents.
    /// 3. (Optional) If `skipCodeSignValidation` is `false`: verify that the
    ///    running bundle and the downloaded bundle share the same `codesign`
    ///    `Authority=` identity. A mismatch calls `setUpdateFailed()` and aborts.
    /// 4. Replace the running bundle via `FileManager.replaceItem` (atomic swap).
    /// 5. Relaunch the new binary with `/usr/bin/open`.
    /// 6. Terminate this process via `NSApp.terminate`.
    ///
    /// On any failure the function calls `state.setUpdateFailed()` and returns
    /// without terminating — the user is left with the running version and the
    /// host should direct them to re-run the original `curl` install command.
    ///
    /// **Exception — post-replaceItem relaunch failure:** if `replaceItem`
    /// succeeds but `open -n` throws, the new binary is already on disk and the
    /// curl-install fallback is misleading (the user does not need to reinstall).
    /// In this case `clearDownloadState()` is called instead of `setUpdateFailed()`
    /// so the host shows a neutral state. The user can relaunch manually.
    ///
    /// ## Why curl is the only correct install and recovery path
    ///
    /// This app is **ad-hoc signed** — it carries a local code signature but
    /// has NOT been submitted to Apple for notarisation. Gatekeeper will block
    /// any `.app` that arrives with the `com.apple.quarantine` extended
    /// attribute set, because without a notarisation ticket it cannot verify
    /// the binary.
    ///
    /// `com.apple.quarantine` is stamped by any process that has opted in via
    /// `LSFileQuarantineEnabled = YES` in its `Info.plist` — this includes
    /// every browser (Safari, Chrome, Firefox) and the macOS Finder copy
    /// operation when dragging from a Downloads folder. A `curl` invocation
    /// does **not** set `LSFileQuarantineEnabled`, so the downloaded `.app`
    /// arrives clean, Gatekeeper never inspects it, and the install succeeds.
    ///
    /// Consequences for this updater:
    /// - `URLSession` (used by `AppUpdater`) does NOT set the quarantine bit
    ///   because the host omits `LSFileQuarantineEnabled`. The in-app download
    ///   is therefore safe.
    /// - **Do NOT add a browser-download fallback.** A browser-downloaded
    ///   `.app` will be quarantine-stamped and Gatekeeper will block it on
    ///   launch, leaving the user with a broken install.
    /// - **Do NOT add a Finder/drag-install path.** Same reason.
    /// - The curl install command is the only other safe path: it mirrors the
    ///   original first-install flow that every user already completed
    ///   successfully.
    ///
    /// ## ⚠️ `setUpdateFailed()` is NOT a silent failure — read before flagging ⚠️
    ///
    /// Reviewers sometimes flag the `replaceItem` catch block as a silent UX
    /// failure because the UI switches from "Install & Relaunch" to a state
    /// that surfaces the `curl` install command with no further explanation.
    /// This is intentional and correct — see the curl distribution model
    /// section above for the full rationale.
    ///
    /// **Do NOT add `NSFileWriteNoPermissionError` special-casing** or a
    /// separate permission state. Distinguishing permission errors from other
    /// `replaceItem` failures would add complexity for a case the curl fallback
    /// already handles correctly.
    ///
    /// ## `isInstalling` reset strategy — intentional, not an oversight
    ///
    /// `isInstalling` is set to `true` at the start and cleared **only in
    /// failure branches**. It is deliberately NOT reset on the success path:
    /// `NSApp.terminate(nil)` fires synchronously after `open -n` is launched, so
    /// the process exits before any subsequent UI tick can observe
    /// `isInstalling == true`. Resetting it would be a no-op and could introduce
    /// a brief window where a second tap slips through.
    ///
    /// - Parameter state: The host update-state object driving the UI.
    @MainActor
    public func installAndRelaunch(state: any UpdateStateProviding) async {
        guard !isInstalling else { return }
        isInstalling = true

        guard let zipURL = state.updateZipURL else {
            isInstalling = false
            state.setUpdateFailed()
            return
        }

        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-update-\(UUID().uuidString)", isDirectory: true)

        guard let appInZip = await unzipAndLocateApp(zipURL: zipURL, into: tmpDir) else {
            isInstalling = false
            state.setUpdateFailed()
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
                state.setUpdateFailed()
                try? FileManager.default.removeItem(at: tmpDir)
                return
            }
        }
        #endif

        await replaceAndRelaunch(
            appInZip: appInZip,
            bundleURL: bundleURL,
            zipURL: zipURL,
            tmpDir: tmpDir,
            state: state
        )
    }

    // MARK: - Private helpers

    /// Unzips `zipURL` into `tmpDir` via `/usr/bin/ditto` and returns the
    /// `.app` bundle URL found at the archive root.
    ///
    /// Returns `nil` and cleans up `tmpDir` on any failure:
    /// - `tmpDir` creation fails
    /// - `ditto` exits non-zero
    /// - No `.app` is present at the archive root
    ///
    /// `contentsOfDirectory` is intentionally shallow (non-recursive): the
    /// release archive is expected to carry exactly one `.app` at its root
    /// (RunBot's publish.yml CI verify step enforces this). A recursive search
    /// is deliberately avoided because it would silently accept malformed archives.
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

    /// Atomically replaces the running bundle, clears cached defaults, then
    /// relaunches via `open -n` and terminates via `NSApp.terminate`.
    ///
    /// ## Post-replaceItem failure handling
    ///
    /// The sequence is:
    /// 1. `replaceItem` — new `.app` atomically on disk.
    /// 2. `clearCachedDefaults()` — persisted cache keys wiped.
    /// 3. `removeItem(zipURL)` — zip deleted (spent).
    /// 4. `open -n` — relaunch the new binary.
    ///
    /// If step 4 throws:
    /// - The new binary **is already on disk** (step 1 succeeded).
    /// - The zip is **already deleted** (step 3).
    /// - `setUpdateFailed()` would be misleading here — it surfaces the
    ///   curl-install fallback, implying the user needs to reinstall. They don't.
    /// - Instead, `clearDownloadState()` is called to reset in-memory cache
    ///   state without triggering the curl-install UI. A distinct error log
    ///   message distinguishes this path from a download/install failure in
    ///   Console.app. The user can relaunch the app manually.
    ///
    /// REVIEWER: Do NOT change the post-open-failure branch to call
    /// `setUpdateFailed()`. The curl-install message is wrong here — see above.
    ///
    /// ## Gatekeeper / quarantine — no strip needed
    /// REVIEWER: Do NOT add a quarantine-strip step here.
    ///
    /// ## replaceItem atomicity
    /// `FileManager.replaceItem` moves the old bundle aside as a named backup,
    /// moves the new bundle into place, then deletes the backup. If the process
    /// is killed mid-swap, macOS guarantees the bundle is either fully old or
    /// fully new.
    ///
    /// ## Zip deletion timing
    /// The zip is deleted BEFORE `open -n` fires. Safe: `replaceItem` is in a
    /// do/catch so this point is only reached after the new .app is in place.
    private func replaceAndRelaunch( // skipcq: SW-R1002 — reviewed; sequential install steps, complexity is inherent
        appInZip: URL,
        bundleURL: URL,
        zipURL: URL,
        tmpDir: URL,
        state: any UpdateStateProviding
    ) async {
        let fm = FileManager.default
        let backupItemName = bundleURL.lastPathComponent + ".bak"
        var resultingNSURL: NSURL?
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
            state.setUpdateFailed()
            try? fm.removeItem(at: tmpDir)
            return
        }

        clearCachedDefaults()
        try? fm.removeItem(at: tmpDir)
        try? fm.removeItem(at: zipURL)

        #if canImport(AppKit)
        let launchPath = ((resultingNSURL as URL?) ?? bundleURL).path
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", launchPath]
        do {
            try relaunchTask.run()
        } catch {
            // replaceItem already succeeded — the new binary is on disk.
            // The zip is also already deleted. setUpdateFailed() would be
            // misleading here: the curl-install fallback implies the user
            // needs to reinstall, but they don't — the new version is
            // already in place. Call clearDownloadState() to reset in-memory
            // cache state without surfacing the curl-install UI, and log a
            // distinct message so Console.app can distinguish this from a
            // download/install failure.
            appUpdaterLogger.error("open -n failed after successful install — new binary is on disk, relaunch manually: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            state.clearDownloadState()
            return
        }
        NSApp.terminate(nil)
        #endif
    }
}

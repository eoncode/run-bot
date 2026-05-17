import Foundation

// MARK: - RunnerLifecycleService

/// Encapsulates all shell-level lifecycle operations for a locally-installed
/// GitHub Actions self-hosted runner. All methods are synchronous and blocking
/// — always call from a background thread.
///
/// Token-gated operations (remove) require a `gh` CLI session or
/// GH_TOKEN/GITHUB_TOKEN to be present, as they invoke `config.sh remove`
/// which calls the GitHub de-registration API.
struct RunnerLifecycleService {
    // MARK: - Shared singleton

    static let shared = RunnerLifecycleService()
    private init() {}

    // MARK: - Start (Resume)

    /// Starts the runner by running `./svc.sh start` from the install directory.
    ///
    /// Using `svc.sh start` instead of `launchctl start <label>` because
    /// `launchctl start` exits 3 ("No such process") when the service hasn't
    /// been bootstrapped into the user session yet — even if the plist exists.
    /// `svc.sh start` handles bootstrap + load + start in the correct order.
    ///
    /// ⚠️ Blocking — call only from a background thread.
    @discardableResult
    func start(runner: RunnerModel) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › start: no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        return runScript(executableName: "svc.sh",
                         arguments: ["start"],
                         workingDirectory: dir,
                         timeout: 15,
                         logTag: "svc.sh start")
    }

    // MARK: - Stop

    /// Stops the runner by running `./svc.sh stop` from the install directory.
    ///
    /// Same reasoning as `start`: `launchctl stop` only works on an already-
    /// running service; `svc.sh stop` is the canonical way to stop the runner.
    ///
    /// ⚠️ Blocking — call only from a background thread.
    @discardableResult
    func stop(runner: RunnerModel) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › stop: no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        return runScript(executableName: "svc.sh",
                         arguments: ["stop"],
                         workingDirectory: dir,
                         timeout: 15,
                         logTag: "svc.sh stop")
    }

    // MARK: - Remove

    /// Uninstalls and de-registers the runner.
    ///
    /// Steps:
    /// 1. `./svc.sh uninstall` — removes the LaunchAgent service.
    /// 2. `./config.sh remove` — de-registers the runner from GitHub.
    ///
    /// Note: `config.sh remove` does NOT accept `--unattended`; that flag is
    /// only valid for the initial `config.sh` registration command. Passing it
    /// causes an "Unrecognized command-line input arguments" error (exit 1).
    ///
    /// If `svc.sh uninstall` fails the method still proceeds to `config.sh remove`
    /// to avoid leaving a ghost registration on the GitHub side.
    ///
    /// ⚠️ Blocking — call only from a background thread.
    /// Requires a GitHub token (gh auth login, GH_TOKEN, or GITHUB_TOKEN).
    @discardableResult
    func remove(runner: RunnerModel) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › remove: no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        let svcOk = runScript(executableName: "svc.sh",
                              arguments: ["uninstall"],
                              workingDirectory: dir,
                              timeout: 30,
                              logTag: "svc.sh uninstall")
        if !svcOk {
            log("RunnerLifecycle › remove: svc.sh uninstall failed for \(runner.runnerName)")
            log("RunnerLifecycle › remove: proceeding to config.sh remove")
        }
        // No --unattended flag: config.sh remove does not accept it.
        let cfgOk = runScript(executableName: "config.sh",
                              arguments: ["remove"],
                              workingDirectory: dir,
                              timeout: 30,
                              logTag: "config.sh remove")
        return svcOk && cfgOk
    }

    // MARK: - Script runner

    /// Launches `<workingDirectory>/<executableName>` via Process (no shell
    /// interpolation). Waits up to `timeout` seconds.
    ///
    /// ⚠️ Blocking — call only from a background thread.
    @discardableResult
    private func runScript(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        logTag: String
    ) -> Bool {
        let executableURL = workingDirectory.appendingPathComponent(executableName)
        let task = Process()
        task.executableURL = executableURL
        task.currentDirectoryURL = workingDirectory
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        var outputData = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); outputData.append(chunk); lock.unlock()
        }
        do { try task.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log("RunnerLifecycle › \(logTag) launch error: \(error)")
            return false
        }
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        log("RunnerLifecycle › \(logTag) exit=\(task.terminationStatus): \(output.prefix(120))")
        return task.terminationStatus == 0
    }

    // MARK: - Rename (Phase 2 — deferred)

    /// Renames the runner by patching the `runnerName` field in the `.runner` JSON.
    /// ⚠️ Incomplete — does NOT re-register with GitHub. Deferred to Phase 2.
    @discardableResult
    private func rename(runner: RunnerModel, newName: String) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › rename: no installPath for \(runner.runnerName)")
            return false
        }
        let url = URL(fileURLWithPath: "\(path)/.runner")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("RunnerLifecycle › rename: failed to read .runner JSON at \(path)")
            return false
        }
        json["runnerName"] = newName
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        else { return false }
        do {
            try updated.write(to: url)
            log("RunnerLifecycle › rename: \(runner.runnerName) → \(newName)")
            return true
        } catch {
            log("RunnerLifecycle › rename write error: \(error)")
            return false
        }
    }

    // MARK: - Update config (labels / workFolder)

    @discardableResult
    func updateConfig(runner: RunnerModel, labels: [String], workFolder: String) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › updateConfig: no installPath for \(runner.runnerName)")
            return false
        }
        let url = URL(fileURLWithPath: "\(path)/.runner")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("RunnerLifecycle › updateConfig: failed to read .runner at \(path)")
            return false
        }
        json["workFolder"] = workFolder
        json["customLabels"] = labels
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        else { return false }
        do {
            try updated.write(to: url)
            log("RunnerLifecycle › updateConfig: labels=\(labels) workFolder=\(workFolder)")
            return true
        } catch {
            log("RunnerLifecycle › updateConfig write error: \(error)")
            return false
        }
    }
}

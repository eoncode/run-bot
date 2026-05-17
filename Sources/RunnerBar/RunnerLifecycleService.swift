import Foundation

// MARK: - RunnerLifecycleService

struct RunnerLifecycleService {
    static let shared = RunnerLifecycleService()
    private init() {}

    // MARK: - Start (Resume)

    /// Starts the runner via `./svc.sh start` from the install directory.
    /// `launchctl start <label>` exits 3 when the service hasn't been bootstrapped;
    /// `svc.sh start` handles bootstrap + load + start in the correct order.
    @discardableResult
    func start(runner: RunnerModel) -> Bool {
        log("RunnerLifecycle › start called for runner=\(runner.runnerName) installPath=\(runner.installPath ?? "nil") gitHubUrl=\(runner.gitHubUrl ?? "nil")")
        guard let path = runner.installPath else {
            log("RunnerLifecycle › start: ABORT — no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        log("RunnerLifecycle › start: running svc.sh start in \(path)")
        let ok = runScript(executableName: "svc.sh",
                           arguments: ["start"],
                           workingDirectory: dir,
                           timeout: 15,
                           logTag: "svc.sh start")
        log("RunnerLifecycle › start: svc.sh start result=\(ok) for \(runner.runnerName)")
        return ok
    }

    // MARK: - Stop

    /// Stops the runner via `./svc.sh stop` from the install directory.
    @discardableResult
    func stop(runner: RunnerModel) -> Bool {
        log("RunnerLifecycle › stop called for runner=\(runner.runnerName) installPath=\(runner.installPath ?? "nil")")
        guard let path = runner.installPath else {
            log("RunnerLifecycle › stop: ABORT — no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        log("RunnerLifecycle › stop: running svc.sh stop in \(path)")
        let ok = runScript(executableName: "svc.sh",
                           arguments: ["stop"],
                           workingDirectory: dir,
                           timeout: 15,
                           logTag: "svc.sh stop")
        log("RunnerLifecycle › stop: svc.sh stop result=\(ok) for \(runner.runnerName)")
        return ok
    }

    // MARK: - Remove

    /// Uninstalls and de-registers the runner.
    ///
    /// Steps:
    /// 1. `./svc.sh uninstall` — removes the LaunchAgent service.
    /// 2. Fetch a removal token from GitHub API.
    /// 3. `./config.sh remove --token <token>` — de-registers from GitHub.
    ///
    /// `config.sh remove` requires `--token <removal-token>` when run non-interactively.
    /// Without it, the script prompts for the token on stdin and hangs/times out.
    @discardableResult
    func remove(runner: RunnerModel) -> Bool {
        log("RunnerLifecycle › remove called for runner=\(runner.runnerName) installPath=\(runner.installPath ?? "nil") gitHubUrl=\(runner.gitHubUrl ?? "nil")")

        guard let path = runner.installPath else {
            log("RunnerLifecycle › remove: ABORT — no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)

        // Step 1: uninstall service
        log("RunnerLifecycle › remove: step 1 — svc.sh uninstall in \(path)")
        let svcOk = runScript(executableName: "svc.sh",
                              arguments: ["uninstall"],
                              workingDirectory: dir,
                              timeout: 30,
                              logTag: "svc.sh uninstall")
        log("RunnerLifecycle › remove: svc.sh uninstall result=\(svcOk) for \(runner.runnerName)")
        if !svcOk {
            log("RunnerLifecycle › remove: svc.sh uninstall failed — continuing to config.sh remove anyway")
        }

        // Step 2: fetch removal token
        log("RunnerLifecycle › remove: step 2 — fetching removal token")
        guard let gitHubUrl = runner.gitHubUrl else {
            log("RunnerLifecycle › remove: ABORT — no gitHubUrl for \(runner.runnerName), cannot fetch removal token")
            return false
        }
        let scope = scopeFromGitHubUrl(gitHubUrl)
        log("RunnerLifecycle › remove: derived scope=\(scope) from gitHubUrl=\(gitHubUrl)")
        guard let token = fetchRemovalToken(scope: scope) else {
            log("RunnerLifecycle › remove: ABORT — fetchRemovalToken returned nil for scope=\(scope)")
            return false
        }
        log("RunnerLifecycle › remove: got removal token for scope=\(scope)")

        // Step 3: config.sh remove --token <token>
        log("RunnerLifecycle › remove: step 3 — config.sh remove --token <token> in \(path)")
        let cfgOk = runScript(executableName: "config.sh",
                              arguments: ["remove", "--token", token],
                              workingDirectory: dir,
                              timeout: 30,
                              logTag: "config.sh remove")
        log("RunnerLifecycle › remove: config.sh remove result=\(cfgOk) for \(runner.runnerName)")
        log("RunnerLifecycle › remove: DONE svcOk=\(svcOk) cfgOk=\(cfgOk) for \(runner.runnerName)")
        return svcOk && cfgOk
    }

    // MARK: - Scope helper

    /// Derives an API scope string ("owner/repo" or "org") from a GitHub URL.
    private func scopeFromGitHubUrl(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else {
            log("RunnerLifecycle › scopeFromGitHubUrl: could not parse URL \(urlString)")
            return urlString
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        log("RunnerLifecycle › scopeFromGitHubUrl: url=\(urlString) parts=\(parts)")
        if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        if parts.count == 1 { return parts[0] }
        log("RunnerLifecycle › scopeFromGitHubUrl: unexpected path structure in \(urlString)")
        return urlString
    }

    // MARK: - Script runner

    @discardableResult
    private func runScript(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        logTag: String
    ) -> Bool {
        let executableURL = workingDirectory.appendingPathComponent(executableName)
        log("RunnerLifecycle › runScript: executableURL=\(executableURL.path) args=\(arguments.filter { !$0.hasPrefix(\"AAAA\") }) cwd=\(workingDirectory.path)")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            log("RunnerLifecycle › runScript: ABORT — not executable or not found: \(executableURL.path)")
            return false
        }
        let task = Process()
        task.executableURL = executableURL
        task.currentDirectoryURL = workingDirectory
        // Redact tokens in log but pass them through to the process
        let safeArgs = arguments.map { $0.count > 20 && !$0.hasPrefix("--") ? "<token>" : $0 }
        log("RunnerLifecycle › runScript: launching \(executableName) \(safeArgs.joined(separator: " "))")
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
        log("RunnerLifecycle › \(logTag) exit=\(task.terminationStatus): \(output.prefix(300))")
        return task.terminationStatus == 0
    }

    // MARK: - Rename (Phase 2 — deferred)

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

    // MARK: - Update config

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

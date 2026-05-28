// RunnerEditCommit.swift
// RunnerBar
// swiftlint:disable missing_docs
import Foundation
import RunnerBarCore

// MARK: - CommitResult

/// The outcome of a `commitRunnerEdit` call.
enum CommitResult {
    /// All requested writes succeeded.
    case success
    /// One or more writes failed. `errors` contains human-readable messages.
    case failure([String])

    /// `true` when the result has no errors.
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// Convenience accessor for the error messages, empty on success.
    var errors: [String] {
        if case .failure(let msgs) = self { return msgs }
        return []
    }
}

// MARK: - commitRunnerEdit

/// Persists all changed fields in `draft` for `runner` as a single transaction.
///
/// Commit order:
/// 1. Labels (GitHub API) — if changed and agentId + scope are available.
///    Aborts before touching disk if this step fails.
/// 2. Runner JSON — workFolder + disableUpdate in one read-modify-write.
/// 3. Proxy files — `.proxy` and `.proxycredentials` only when changed.
///
/// Always dispatches `completion` on the main queue.
func commitRunnerEdit(
    runner: RunnerModel,
    draft: RunnerEditDraft,
    original: RunnerEditDraft,
    completion: @escaping (CommitResult) -> Void
) {
    DispatchQueue.global(qos: .userInitiated).async {
        var errors: [String] = []

        // MARK: Step 1 — Labels (GitHub API)
        let labelsChanged = draft.parsedLabels != original.parsedLabels
        if labelsChanged {
            if let agentId = runner.agentId,
               let gitHubUrl = runner.gitHubUrl,
               let scope = scopeFromHtmlUrl(gitHubUrl) {
                log("commitRunnerEdit › patching labels runner=\(runner.runnerName) labels=\(draft.parsedLabels)")
                let result = patchRunnerLabels(scope: scope, runnerID: agentId, labels: draft.parsedLabels)
                if result == nil {
                    log("commitRunnerEdit › labels API failed, aborting")
                    let msg = "Failed to save labels via GitHub API"
                    DispatchQueue.main.async { completion(.failure([msg])) }
                    return // abort — do not touch local files
                }
                log("commitRunnerEdit › labels patched ok")
            } else {
                let msg = "Cannot save labels: missing agent ID or GitHub URL"
                log("commitRunnerEdit › \(msg)")
                errors.append(msg)
                // Non-fatal for local writes; continue
            }
        }

        // MARK: Step 2 — Runner JSON (workFolder + disableUpdate)
        let workFolderChanged = draft.trimmedWorkFolder != original.trimmedWorkFolder
        let autoUpdateChanged = draft.autoUpdate != original.autoUpdate
        if workFolderChanged || autoUpdateChanged {
            guard let installPath = runner.installPath else {
                errors.append("Install path unknown — cannot write runner JSON")
                finalize(errors, completion)
                return
            }
            log("commitRunnerEdit › patching .runner JSON installPath=\(installPath)")
            let jsonOk = patchRunnerJSONMulti(
                installPath: installPath,
                patches: [
                    "workFolder": draft.trimmedWorkFolder,
                    "disableUpdate": !draft.autoUpdate
                ]
            )
            if !jsonOk {
                errors.append("Failed to write runner configuration (.runner JSON)")
                log("commitRunnerEdit › .runner JSON write failed")
            } else {
                log("commitRunnerEdit › .runner JSON updated ok")
            }
        }

        // MARK: Step 3 — Proxy files
        let proxyChanged = draft.proxyUrl != original.proxyUrl
            || draft.proxyUser != original.proxyUser
            || draft.proxyPassword != original.proxyPassword
        if proxyChanged {
            guard let installPath = runner.installPath else {
                errors.append("Install path unknown — cannot write proxy files")
                finalize(errors, completion)
                return
            }
            log("commitRunnerEdit › writing proxy files installPath=\(installPath)")
            let proxyOk = writeProxyFiles(
                installPath: installPath,
                url: draft.proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                user: draft.proxyUser.trimmingCharacters(in: .whitespacesAndNewlines),
                password: draft.proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if !proxyOk {
                errors.append("Failed to save proxy settings")
                log("commitRunnerEdit › proxy write failed")
            } else {
                log("commitRunnerEdit › proxy files updated ok")
            }
        }

        finalize(errors, completion)
    }
}

// MARK: - Private helpers

/// Dispatches the final `CommitResult` on the main queue.
private func finalize(_ errors: [String], _ completion: @escaping (CommitResult) -> Void) {
    DispatchQueue.main.async {
        completion(errors.isEmpty ? .success : .failure(errors))
    }
}

/// Reads the `.runner` JSON at `installPath`, merges all `patches` in one pass, and writes back.
/// Accepts mixed `String` and `Bool` values via `Any`.
private func patchRunnerJSONMulti(installPath: String, patches: [String: Any]) -> Bool {
    let path = installPath + "/.runner"
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        log("patchRunnerJSONMulti › failed to read \(path)")
        return false
    }
    for (key, value) in patches { json[key] = value }
    guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
        log("patchRunnerJSONMulti › serialization failed")
        return false
    }
    do {
        try newData.write(to: url, options: .atomic)
        log("patchRunnerJSONMulti › wrote keys=\(patches.keys.sorted()) to \(path)")
        return true
    } catch {
        log("patchRunnerJSONMulti › write error: \(error)")
        return false
    }
}

/// Writes (or removes) `.proxy` and `.proxycredentials` files at `installPath`.
private func writeProxyFiles(installPath: String, url: String, user: String, password: String) -> Bool {
    var ok = true
    let proxyFilePath = installPath + "/.proxy"
    let credPath = installPath + "/.proxycredentials"

    // .proxy
    do {
        if url.isEmpty {
            if FileManager.default.fileExists(atPath: proxyFilePath) {
                try FileManager.default.removeItem(atPath: proxyFilePath)
                log("writeProxyFiles › removed .proxy")
            }
        } else {
            try url.write(toFile: proxyFilePath, atomically: true, encoding: .utf8)
            log("writeProxyFiles › wrote .proxy")
        }
    } catch {
        log("writeProxyFiles › .proxy error: \(error)")
        ok = false
    }

    // .proxycredentials
    do {
        if user.isEmpty && password.isEmpty {
            if FileManager.default.fileExists(atPath: credPath) {
                try FileManager.default.removeItem(atPath: credPath)
                log("writeProxyFiles › removed .proxycredentials")
            }
        } else {
            try "\(user)\n\(password)".write(toFile: credPath, atomically: true, encoding: .utf8)
            log("writeProxyFiles › wrote .proxycredentials")
        }
    } catch {
        log("writeProxyFiles › .proxycredentials error: \(error)")
        ok = false
    }

    return ok
}
// swiftlint:enable missing_docs

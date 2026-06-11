// RunnerProxyStore.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - RunnerProxyStoreError

/// Errors thrown while writing proxy files.
enum RunnerProxyStoreError: LocalizedError {
    /// One or more proxy files could not be written or removed.
    /// `messages` contains a human-readable description for each failing file.
    case writeFailed([String])

    /// A human-readable description of the error, suitable for display in alerts.
    var errorDescription: String? {
        switch self {
        case .writeFailed(let messages):
            "Failed to write proxy files: " + messages.joined(separator: "; ")
        }
    }
}

// MARK: - RunnerProxyStore

/// Actor that owns all disk read/write for runner proxy configuration files.
///
/// Conforms to `RunnerProxyStoreProtocol` so it can be replaced with a test double
/// when injected into `SaveRunnerEditsUseCase`.
///
/// Replaces the `loadProxy` private helper in `RunnerEditDraft` and the
/// `writeProxyFiles` / `removeIfPresent` free functions in `CommitRunnerEdit`.
///
/// Disk operations are dispatched to a background `DispatchQueue` so the
/// actor's cooperative thread is never blocked by synchronous file I/O.
///
/// File format (unchanged from previous implementation):
/// - `.proxy`            — raw proxy URL followed by `"\n"`.
/// - `.proxycredentials` — `user + "\n" + password + "\n"`.
///
/// - Note: Part of Phase 4 of the Swift 6.2 data model modernisation (#1287, #1299).
actor RunnerProxyStore: RunnerProxyStoreProtocol {

    // MARK: Shared instance

    /// The shared singleton instance.
    static let shared = RunnerProxyStore()

    // MARK: Init

    /// Use `RunnerProxyStore.shared` — direct instantiation is not permitted.
    private init() { /* singleton — use RunnerProxyStore.shared */ }

    // MARK: - load(at:)

    /// Reads `.proxy` and `.proxycredentials` at `installPath` on a background thread.
    ///
    /// This method is **non-throwing**: missing proxy files are the normal
    /// case (most runners have no proxy). A zeroed `RunnerProxyConfig` is
    /// returned whenever either or both files are absent.
    func load(at installPath: String) async -> RunnerProxyConfig {
        let base     = URL(fileURLWithPath: installPath)
        let proxyURL = base.appendingPathComponent(".proxy")
        let credURL  = base.appendingPathComponent(".proxycredentials")

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let url: String
                do {
                    url = try String(contentsOf: proxyURL, encoding: .utf8)
                        .trimmingCharacters(in: .newlines)
                } catch let err as NSError where err.code == NSFileNoSuchFileError {
                    url = ""
                } catch {
                    log("RunnerProxyStore › .proxy read error (using empty): \(error)")
                    url = ""
                }

                var user = ""
                var proxyCredential = ""
                do {
                    let credContent = try String(contentsOf: credURL, encoding: .utf8)
                    (user, proxyCredential) = Self.parseCredentialLines(credContent)
                } catch let err as NSError where err.code == NSFileNoSuchFileError {
                    // Missing credentials file is expected — most runners have no proxy.
                } catch {
                    log("RunnerProxyStore › .proxycredentials read error (using empty): \(error)")
                }

                continuation.resume(returning: RunnerProxyConfig(url: url, user: user, password: proxyCredential))
            }
        }
    }

    // MARK: - save(_:at:)

    /// Writes (or removes) `.proxy` and `.proxycredentials` at `installPath`
    /// on a background thread.
    ///
    /// Each file is handled independently so a failure on one does not mask
    /// a failure on the other. Both errors are logged; if either write fails
    /// `RunnerProxyStoreError.writeFailed` is thrown with all messages.
    func save(_ config: RunnerProxyConfig, at installPath: String) async throws {
        let base     = URL(fileURLWithPath: installPath)
        let proxyURL = base.appendingPathComponent(".proxy")
        let credURL  = base.appendingPathComponent(".proxycredentials")

        let url            = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let user           = config.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxySecretVal = config.password.trimmingCharacters(in: .whitespacesAndNewlines)

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var messages: [String] = []

                do {
                    try Self.writeProxyURL(url, to: proxyURL)
                } catch {
                    let m = ".proxy write error: \(error)"
                    log("RunnerProxyStore › \(m)")
                    messages.append(m)
                }

                do {
                    try Self.writeProxyCredentials(user: user, secret: proxySecretVal, to: credURL)
                } catch {
                    let m = ".proxycredentials write error: \(error)"
                    log("RunnerProxyStore › \(m)")
                    messages.append(m)
                }

                if messages.isEmpty {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RunnerProxyStoreError.writeFailed(messages))
                }
            }
        }
    }

    // MARK: - Private helpers

    private static func parseCredentialLines(_ content: String) -> (user: String, password: String) {
        let lines      = content.components(separatedBy: "\n")
        let user       = lines.first.map { $0.trimmingCharacters(in: .newlines) } ?? ""
        let credential = lines.indices.contains(1) ? lines[1].trimmingCharacters(in: .newlines) : ""
        return (user, credential)
    }

    private static func writeProxyURL(_ url: String, to destination: URL) throws {
        if url.isEmpty {
            try removeIfPresent(at: destination)
        } else {
            try (url + "\n").write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    private static func writeProxyCredentials(user: String, secret: String, to destination: URL) throws {
        if user.isEmpty && secret.isEmpty {
            try removeIfPresent(at: destination)
        } else {
            try (user + "\n" + secret + "\n").write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    private static func removeIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // File didn't exist — expected, not an error.
        }
    }
}

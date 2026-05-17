import Combine
import Foundation

// MARK: - LocalRunnerStore

/// An `ObservableObject` that drives the Local Runners section of `SettingsView`.
///
/// Wraps `LocalRunnerScanner` and exposes the result as a published array so
/// SwiftUI views automatically re-render when the scan completes or is refreshed.
///
/// **Threading:** scanning is dispatched to a background queue to avoid blocking
/// the main thread. `runners` is always updated on the main queue.
///
/// **Phase 4:** After the local scan, `RunnerStatusEnricher` is called on the
/// same background thread to enrich each runner with live GitHub API status
/// (online/offline/busy). Enrichment is skipped silently when no GitHub token
/// is present, preserving Phase 1 behaviour for unauthenticated users.
///
/// `@unchecked Sendable`: all mutable state is protected by DispatchQueue
/// serialisation (background queue for reads, main queue for writes to
/// `@Published` properties). Safe to cross actor boundaries.
final class LocalRunnerStore: ObservableObject, @unchecked Sendable {
    // MARK: Shared singleton

    static let shared = LocalRunnerStore()

    // MARK: Published state

    /// The list of locally-discovered runners. Empty until the first scan completes.
    @Published private(set) var runners: [RunnerModel] = []

    /// `true` while a background scan is in progress.
    @Published private(set) var isScanning: Bool = false

    // MARK: Persisted install paths

    /// UserDefaults key for runner install directories registered via AddRunnerSheet.
    private static let installedPathsKey = "dev.eonist.runnerbar.installedRunnerPaths"

    /// Absolute paths of runner install directories that were registered through
    /// the Add Runner sheet. Persisted in UserDefaults so they survive app restarts
    /// and are fed into LocalRunnerScanner as additional search roots.
    private(set) var installedPaths: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: Self.installedPathsKey) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.installedPathsKey)
        }
    }

    /// Registers a runner install directory so it is included in future scans.
    /// Safe to call from any thread — UserDefaults writes are thread-safe.
    func addInstalledPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var current = installedPaths
        guard !current.contains(trimmed) else { return }
        current.append(trimmed)
        installedPaths = current
    }

    // MARK: Private

    private let scanner = LocalRunnerScanner()
    private let enricher = RunnerStatusEnricher.shared
    private let queue = DispatchQueue(
        label: "dev.eonist.runnerbar.localrunnerstore",
        qos: .userInitiated
    )

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Triggers a fresh scan on a background thread. The published `runners`
    /// array is updated on the main thread when the scan and optional enrichment
    /// finish.
    ///
    /// `@MainActor` enforces the main-thread call-site contract at compile time.
    /// `isScanning = true` is set synchronously before dispatching background
    /// work to close the race window where two rapid calls could both pass the guard.
    ///
    /// ⚠️ REGRESSION GUARD: `isScanning = true` must remain synchronous here.
    @MainActor
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let extraPaths = installedPaths
        queue.async { [weak self] in
            guard let self else { return }
            // Phase 1: local scan — include any paths registered via Add Runner sheet
            var result = self.scanner.scan(extraPaths: extraPaths)
            // Phase 4: enrich with live GitHub API status (skipped if no token)
            if githubToken() != nil {
                result = self.enricher.enrich(runners: result)
            }
            DispatchQueue.main.async {
                self.runners = result
                self.isScanning = false
            }
        }
    }
}

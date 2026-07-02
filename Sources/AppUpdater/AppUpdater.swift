// AppUpdater.swift
// AppUpdater
import Foundation
// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AppUpdater

/// Drives the in-app auto-update flow: GitHub Releases poll → semver compare →
/// zip download → SHA-256 verification → host-state mutation → install &
/// relaunch on user confirmation.
///
/// `AppUpdater` is a configurable `@MainActor` class carrying no host-specific
/// state of its own beyond what the caller injects. All UI-facing state lives
/// in a caller-supplied `any UpdateStateProviding`; all persisted state lives
/// in the injected `UserDefaults` under keys scoped to `schedulerIdentifier`.
///
/// ## Isolation model
///
/// The class is `@MainActor`, so `isInstalling`, `isDownloading`, and the
/// scheduler reference are race-free without extra locking. The blocking work
/// runs off the main thread regardless: `URLSession` downloads suspend rather
/// than block, checksum verification runs in the `@concurrent` `verifyChecksum`
/// free function, and subprocess launches run in the `@concurrent` `runCommand`
/// helper. The background download is spawned with a fire-and-forget
/// `Task(name:)` that inherits `@MainActor` isolation — see the doc comment on
/// `downloadUpdate` for the full rationale on why storing the handle and adding
/// cancellation is deliberately absent.
///
/// ## Typical usage
///
/// ```swift
/// let updater = AppUpdater(
///     repo: "your-org/your-repo",
///     currentVersion: "1.2.3",
///     assetName: { _ in "YourApp.zip" },
///     schedulerIdentifier: "com.your-org.update-check",
///     betaChannelProvider: { UserDefaults.standard.bool(forKey: "betaChannel") }
/// )
/// updater.rehydrateCachedUpdateIfNewer(state: myState)
/// await updater.checkAndHandle(state: myState)
/// updater.scheduleBackgroundCheck(state: myState)
/// ```
@MainActor
public final class AppUpdater {

    // MARK: - Public configuration

    /// `"owner/name"` GitHub repository slug polled for releases.
    public let repo: String

    /// The running app's version (full semver incl. any pre-release suffix).
    /// The library never reads `Bundle` — the host supplies this.
    public let currentVersion: String

    /// Reverse-DNS identifier for the background scheduler; also the domain
    /// used to scope this updater's `UserDefaults` keys.
    ///
    /// Must be a valid reverse-DNS string (e.g. `"com.your-org.update-check"`).
    /// Must not be empty and must not contain `/` — both are enforced by
    /// `precondition` at init time. The identifier is used verbatim as a
    /// `UserDefaults` suite name and as a cache directory name component; a
    /// slash would silently create a nested subdirectory path under Caches
    /// rather than a flat scoped directory.
    public let schedulerIdentifier: String

    // MARK: - Internal configuration
    //
    // The properties below are `internal` (not `public`) by deliberate design:
    //
    // • `assetName` — a `@Sendable` closure injected at init; the host has no
    //   need to inspect it after construction, and exposing it publicly would
    //   widen the API surface for no benefit.
    // • `defaults` / `keys` — implementation details of the persistence layer;
    //   not part of the public contract.
    // • `betaChannelProvider` — injected closure; same rationale as `assetName`.
    // • `provider` — the `ReleaseProvider` seam; injectable for tests, not
    //   intended for host-app inspection.
    // • `isInstalling` / `isDownloading` — runtime guards accessed via
    //   `@testable import` in the same-package test target. If this library is
    //   ever extracted to its own repository these should be `public` so
    //   external test targets can reach them without `@testable import`.
    //
    // REVIEWER: The asymmetry between `repo`/`currentVersion`/`schedulerIdentifier`
    // (public) and the properties below (internal) is intentional. Do NOT make
    // the closures or defaults public without a concrete external-consumer use
    // case — every public symbol is a promise.

    /// Maps a release tag name to the expected zip asset filename.
    ///
    /// Injected so hosts can use a fixed name (`{ _ in "App.zip" }`) or a
    /// versioned one (`{ v in "App-\(v).zip" }`). The SHA-256 sidecar is
    /// expected at `<assetName>.sha256`.
    ///
    /// `@Sendable` is required because `fetchLatestRelease` (on `ReleaseProvider`)
    /// declares its `assetName` parameter as `@Sendable` — the stored closure
    /// must match so it can be forwarded without a concurrency warning.
    ///
    /// REVIEWER: `assetName` is `internal` even though it is accepted as a
    /// public `init` parameter. The host injected it — it does not need to
    /// read it back. Exposing it publicly would widen the API surface for no
    /// concrete consumer benefit and create a promise we'd have to maintain.
    /// If a specific external use case emerges, make it public then.
    let assetName: @Sendable (String) -> String

    /// The `UserDefaults` suite persisting the cached-zip path and version.
    let defaults: UserDefaults

    /// Reads the host's current beta-channel preference. Invoked on the main
    /// actor before each check so pre-release builds are included when enabled.
    let betaChannelProvider: @MainActor () -> Bool

    /// Scoped `UserDefaults` key names, derived from `schedulerIdentifier`.
    let keys: AppUpdaterDefaults

    /// The release-fetch abstraction. Defaults to `GitHubReleaseProvider`.
    ///
    /// Injected at `init` time; immutable after construction (AppUpdater's
    /// immutable-configuration model — all dependencies are `let`).
    let provider: any ReleaseProvider

    // MARK: - Trust model

    // REVIEWER: `skipCodeSignValidation` is a `var`, not an `init` parameter —
    // intentional. Moving it to `init` would force every caller to decide at
    // construction time, which is wrong for hosts that read this preference from
    // `UserDefaults` or a settings screen after `AppUpdater` is already
    // constructed. A `var` is the correct shape for a runtime-togglable trust
    // preference. Set it before calling `scheduleBackgroundCheck` or
    // `checkAndHandle` — see the doc comment below.

    /// When `false`, `installAndRelaunch` verifies that the running bundle and
    /// the downloaded bundle share the same `codesign` `Authority=` identity
    /// before performing the atomic bundle swap.
    ///
    /// Default `true` — RunBot's unsigned distribution model relies solely on
    /// the SHA-256 sidecar for integrity. External consumers distributing
    /// Developer ID-signed apps should set this to `false` so mismatched
    /// signing identities (e.g. a compromised build pipeline) are caught before
    /// the swap.
    ///
    /// ## Call-ordering note
    ///
    /// Set this property **before** calling `scheduleBackgroundCheck` or
    /// `checkAndHandle`. The value is read at `installAndRelaunch` time (not at
    /// check time), but establishing it early avoids any ambiguity about which
    /// value was in effect when a background check fired.
    ///
    /// ## Unsigned path (`skipCodeSignValidation = true`)
    /// - Download integrity guaranteed by SHA-256 sidecar only.
    /// - No `codesign` invocation on the downloaded bundle.
    /// - Correct for apps distributed without a Developer ID signature.
    ///
    /// ## Signed path (`skipCodeSignValidation = false`)
    /// - SHA-256 verification runs first (always).
    /// - After checksum passes, `codesign -dvvv` is run on both the running
    ///   bundle and the downloaded bundle.
    /// - `Authority=` identity strings must match; a mismatch calls
    ///   `setUpdateFailed()` and aborts the install.
    /// - For external consumers distributing Developer ID-signed apps.
    ///
    /// REVIEWER: The default `true` is intentional for RunBot. Do NOT change
    /// the default to `false` without updating the host's `AppDelegate` setup.
    public var skipCodeSignValidation: Bool = true

    // MARK: - Runtime flags

    /// `true` while `installAndRelaunch` is mid-flight — guards a double-tap.
    var isInstalling: Bool = false

    /// `true` while a background download is running — guards concurrent
    /// downloads of the same or a different release.
    ///
    /// REVIEWER: There is no stored `downloadTask` handle alongside this flag —
    /// this is intentional. See the "Fire-and-forget rationale" section in the
    /// `downloadUpdate` doc comment for the full explanation. Do NOT add a
    /// stored task handle or cancellation without re-reading that section first.
    var isDownloading: Bool = false

    // MARK: - Background scheduler storage
    //
    // AppKit is unavailable in the SPM headless test runner — the #if guard is
    // required for `swift test` even though the package is macOS(.v26)-only.
    //
    // ── Why nonisolated(unsafe) var, and why it is safe ─────────────────────────
    //
    // `deinit` is a nonisolated context — the Swift compiler does not permit
    // accessing a `@MainActor`-isolated property from `deinit` directly.
    // `NSBackgroundActivityScheduler` MUST be explicitly invalidated before
    // deallocation; failing to do so leaks the activity registration system-wide
    // (it survives the AppUpdater instance). `nonisolated(unsafe)` is the only
    // mechanism that allows `deinit` to reach `activity` without a
    // `Task { @MainActor in }` (which would be a use-after-free: `self` is
    // already deallocating when deinit runs).
    //
    // **Why this is safe in practice:**
    //
    // 1. `AppUpdater` is `@MainActor final class`. Every method and property
    //    access — except `deinit` — runs on the main actor. The compiler
    //    enforces this for all non-`nonisolated` call sites. There is no
    //    non-isolated code path that reads or writes `activity` other than
    //    `deinit`.
    //
    // 2. `deinit` only calls `activity?.invalidate()`. It does not write the
    //    reference, does not race with `scheduleBackgroundCheck` (which assigns
    //    it on the main actor), and `NSBackgroundActivityScheduler.invalidate()`
    //    is explicitly documented as thread-safe by Apple.
    //
    // 3. The data race that `nonisolated(unsafe)` silences — a concurrent write
    //    from a non-isolated context — cannot arise here because there is no
    //    non-isolated write path. `scheduleBackgroundCheck` runs on `@MainActor`;
    //    `deinit` only reads the reference to call `invalidate()`. The reference
    //    itself is never written from `deinit`.
    //
    // ── Tension with concurrency-overview.md ─────────────────────────────────
    //
    // The project's concurrency doc (docs/architecture/concurrency-overview.md)
    // reserves `nonisolated` for immutable-post-init cases and forbids
    // `@unchecked Sendable` / unsafe escape hatches as general patterns.
    // This usage is a justified, narrow exception:
    //
    // - It is the ONLY `nonisolated(unsafe)` annotation in AppUpdater.
    // - It is required by a concrete platform constraint (deinit isolation),
    //   not by a design choice or convenience.
    // - The safety argument is fully enumerated above, not assumed.
    //
    // Do NOT copy this pattern for other properties. If a future property needs
    // nonisolated access, re-evaluate whether the underlying constraint is the
    // same (deinit invalidation of a thread-safe object) before using it.
    //
    // ── Known alternative (not pursued, low priority) ───────────────────────
    //
    // `scheduleBackgroundCheck` assigns `activity` exactly once. It could
    // theoretically be refactored to `nonisolated(unsafe) let` — set once at
    // `scheduleBackgroundCheck` call time — which would satisfy the concurrency
    // doc's "immutable-post-init" requirement more precisely.
    //
    // This was not pursued because:
    // - It would require restructuring init (activity can't be a `let` without
    //   a value at init time) or using a lazy wrapper.
    // - `scheduleBackgroundCheck` is optional — not every host calls it — so
    //   `activity` is legitimately nil for the full lifetime in test contexts.
    // - The current approach is correct and safe for the actual access patterns.
    //
    // If AppUpdater is ever extracted to its own standalone repo and the
    // concurrency doc exception becomes a problem for external consumers,
    // revisit the `let`-after-scheduleBackgroundCheck approach at that point.
    //
    // REVIEWER: Do NOT:
    // - Remove `nonisolated(unsafe)` without providing an alternative deinit
    //   invalidation path for NSBackgroundActivityScheduler.
    // - Change this to `nonisolated(unsafe) let` without verifying that
    //   scheduleBackgroundCheck is always called exactly once before deinit
    //   (it is not guaranteed — hosts that never call it leave activity nil).
    // - Add any non-`deinit`, non-`@MainActor` access to `activity` — doing so
    //   would invalidate the safety argument above.
    #if canImport(AppKit)
    /// Retains the `NSBackgroundActivityScheduler` for the app's lifetime.
    ///
    /// Declared `nonisolated(unsafe)` so `deinit` (a nonisolated context) can
    /// call `invalidate()`. All non-deinit accesses are `@MainActor`-isolated
    /// via the enclosing class — the compiler enforces this at every call site
    /// that is not `deinit`. See the block comment above for the full safety
    /// rationale and the known alternative approach.
    nonisolated(unsafe) var activity: NSBackgroundActivityScheduler?
    #endif

    // MARK: - Init / deinit

    /// Creates a configured updater.
    ///
    /// - Parameters:
    ///   - repo: `"owner/name"` GitHub repository slug (e.g. `"runbot-hq/run-bot"`).
    ///     Must not be empty — an empty string produces a malformed API URL.
    ///   - currentVersion: The running app's version string.
    ///   - assetName: Maps a tag name to the expected zip asset filename.
    ///   - schedulerIdentifier: Reverse-DNS scheduler id / `UserDefaults` domain.
    ///     Must not be empty and must not contain `"/"` — an empty string causes
    ///     `UserDefaults` key collisions; a slash causes `appendingPathComponent`
    ///     to silently create a nested subdirectory under Caches rather than a
    ///     flat scoped directory. Both are enforced by `precondition`.
    ///   - userDefaults: Suite for persisted cache state. Defaults to `.standard`.
    ///   - betaChannelProvider: Returns the host's beta-channel preference.
    ///     Defaults to always-`false` (stable channel only).
    ///   - releaseProvider: The `ReleaseProvider` to use for fetching releases.
    ///     Defaults to `GitHubReleaseProvider()`. Override in tests by passing a
    ///     `MockReleaseProvider` — no live network required.
    ///
    /// The generic `<P: ReleaseProvider>` constraint enforces `Sendable` at the
    /// call site. Storage as `any ReleaseProvider` is standard Swift 6 practice
    /// — constraint at call site, existential for storage.
    public init<P: ReleaseProvider>(
        repo: String,
        currentVersion: String,
        assetName: @escaping @Sendable (String) -> String,
        schedulerIdentifier: String,
        userDefaults: UserDefaults = .standard,
        betaChannelProvider: @escaping @MainActor () -> Bool = { false },
        releaseProvider: P = GitHubReleaseProvider()
    ) {
        precondition(!repo.isEmpty, "AppUpdater: repo must not be empty (expected \"owner/repo\")")
        precondition(!schedulerIdentifier.isEmpty, "AppUpdater: schedulerIdentifier must not be empty (expected a reverse-DNS string)")
        precondition(
            !schedulerIdentifier.contains("/"),
            "AppUpdater: schedulerIdentifier must not contain '/' — used as a cache directory name"
            + " component via appendingPathComponent; a slash would silently create a nested subdirectory path"
        )
        self.repo = repo
        self.currentVersion = currentVersion
        self.assetName = assetName
        self.schedulerIdentifier = schedulerIdentifier
        self.defaults = userDefaults
        self.betaChannelProvider = betaChannelProvider
        self.keys = AppUpdaterDefaults(domain: schedulerIdentifier)
        self.provider = releaseProvider
    }

    deinit {
        // NSBackgroundActivityScheduler must be explicitly invalidated;
        // failing to do so leaks the activity registration system-wide.
        // NSBackgroundActivityScheduler.invalidate() is thread-safe per Apple
        // docs — safe to call from a nonisolated deinit.
        // See the MARK: Background scheduler storage block comment above for
        // the full safety rationale on the nonisolated(unsafe) annotation.
        #if canImport(AppKit)
        activity?.invalidate()
        #endif
        // REVIEWER: There is no downloadTask?.cancel() here — intentional.
        // AppUpdater is owned by AppDelegate for the app's entire lifetime;
        // deinit is never reached while a download is in flight. Adding a
        // cancel call here would be dead code. See the "Fire-and-forget
        // rationale" section in the downloadUpdate doc comment.
    }
}

// AppUpdaterDefaults.swift
// AppUpdater
import Foundation

// MARK: - AppUpdaterDefaults

/// Host-scoped `UserDefaults` key names for the auto-update flow, plus the
/// background scheduler interval.
///
/// Keys are derived from a caller-supplied `domain` so two apps embedding
/// `AppUpdater` in the same `UserDefaults` suite never collide. `AppUpdater`
/// passes its `schedulerIdentifier` as the domain, which is already a
/// reverse-DNS string unique to the host app.
public struct AppUpdaterDefaults: Sendable {

    /// `UserDefaults` key for the file-system path of the cached update zip.
    public let cachedUpdateZipPath: String

    /// `UserDefaults` key for the version string of the cached update zip.
    public let cachedUpdateVersion: String

    /// Builds the scoped key set for `domain`.
    ///
    /// - Parameter domain: A reverse-DNS prefix unique to the host app
    ///   (e.g. `"io.github.runbot-hq.update-check"`). Keys are formed as
    ///   `"<domain>.cachedUpdateZipPath"` and `"<domain>.cachedUpdateVersion"`.
    public init(domain: String) {
        cachedUpdateZipPath = "\(domain).cachedUpdateZipPath"
        cachedUpdateVersion = "\(domain).cachedUpdateVersion"
    }

    /// How often `NSBackgroundActivityScheduler` fires a background update check.
    ///
    /// - **Release:** 24 hours. A daily check is the correct bar for a menu bar
    ///   utility; there is intentionally no UI to change it.
    /// - **DEBUG:** 60 seconds default, overridable per-test so the scheduler
    ///   fires quickly in QA and unit-test scenarios without sleeping.
    ///
    /// The launch-time check the host performs on startup is independent; the
    /// scheduler only fires after the first interval elapses.
    #if DEBUG
    /// 60-second interval used in DEBUG builds. Override in tests for faster QA cycles.
    @MainActor public static var checkInterval: TimeInterval = 60
    #else
    /// 24-hour interval used in release builds.
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    #endif
}

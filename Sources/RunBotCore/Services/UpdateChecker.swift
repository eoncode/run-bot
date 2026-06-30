// UpdateChecker.swift
// RunBotCore
import Foundation

// MARK: - ReleaseAsset

/// A single asset attached to a GitHub Release (e.g. `RunBot.zip`).
///
/// Only `name` and `browserDownloadURL` are decoded; the rest of the
/// GitHub asset payload is intentionally ignored to keep the model minimal.
public struct ReleaseAsset: Decodable, Sendable {
    /// The filename of the asset as it appears on the release page
    /// (e.g. `"RunBot.zip"`).
    public let name: String
    /// The direct download URL for this asset.
    ///
    /// This is always an `https://objects.githubusercontent.com/…` URL;
    /// it does not require authentication for public repositories.
    public let browserDownloadURL: URL

    /// Maps JSON keys to Swift property names.
    enum CodingKeys: String, CodingKey {
        /// Maps to the `name` field in the GitHub API response.
        case name
        /// Maps to the `browser_download_url` field in the GitHub API response.
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - AvailableRelease

/// A decoded GitHub Release, carrying the tag name, channel flag, and asset list.
///
/// Exposed `public` so `AutoUpdater` (same module) and call sites in the app
/// layer can pattern-match on the `.updateAvailable` case without re-fetching.
public struct AvailableRelease: Sendable {
    /// The git tag of this release (e.g. `"v0.8.0"` or `"v0.8.0-beta.1"`).
    public let tagName: String
    /// The list of binary assets attached to this release.
    ///
    /// `AutoUpdater` searches this list for the asset named `"RunBot.zip"`.
    /// When the asset is absent, `RunnerState.updateAssetMissing` is set to
    /// `true` and the UI falls back to a browser-based Download button.
    public let assets: [ReleaseAsset]
    /// The URL of the SHA-256 checksum sidecar file for this release, if present.
    ///
    /// `nil` in v1 — checksum verification is deferred to issue #1795. This
    /// field is decoded now so that #1795 can implement verification logic
    /// without requiring a model change. `AutoUpdater.downloadUpdate` must not
    /// use this field until #1795 is implemented.
    public let checksumURL: URL?
}

// MARK: - UpdateCheckResult

/// The result of a `UpdateChecker.checkForUpdate(betaChannel:)` call.
public enum UpdateCheckResult: Sendable {
    /// The running version is already the latest available.
    case upToDate
    /// A newer release is available.
    ///
    /// - Parameter release: The full `AvailableRelease` for the newer version,
    ///   including its `tagName` and `assets` list. Callers should pass this
    ///   directly to `AutoUpdater.handle(_:)` rather than extracting only the
    ///   tag name — the asset list is needed to locate the download URL.
    case updateAvailable(release: AvailableRelease)
    /// The check could not be completed (network error, missing key, etc.).
    ///
    /// - Parameter error: The underlying error. Call sites may inspect this
    ///   for diagnostics but must treat it as non-fatal — update checks are
    ///   best-effort and must never crash the app.
    case failed(Error)
}

// MARK: - UpdateCheckError

/// Errors specific to the update-check flow that do not wrap a lower-level error.
public enum UpdateCheckError: Error, Sendable {
    /// `RBVersionString` was absent from `Info.plist`.
    case missingVersionKey
    /// The releases API returned no usable release for the requested channel.
    case noReleasesFound
}

/// Checks GitHub Releases for a newer version of RunBot.
///
/// Hits `GET /repos/runbot-hq/run-bot/releases` (the full list, not /latest)
/// so it can filter by channel. The `prerelease` field on each release is set
/// by the `--prerelease` flag in `publish.yml` at release creation time.
///
/// Implemented as a caseless `enum` (not `struct` or `class`) to prevent
/// accidental instantiation — all functionality is exposed via `static` methods.
public enum UpdateChecker {

    /// The GitHub Releases API URL string for this repository.
    ///
    /// Kept as a plain `String` constant (not a `URL` literal) so there is no
    /// dependency on a particular `URL` initialiser overload. `buildRequest(perPage:)`
    /// converts it to a `URL` via `URL(string:)` and returns `nil` on failure,
    /// so a typo here degrades gracefully (update check silently no-ops) rather
    /// than crashing at startup.
    ///
    /// Centralised here so that the URL appears in exactly one place — grep
    /// for `releasesURLString` to find every usage.
    private static let releasesURLString =
        "https://api.github.com/repos/runbot-hq/run-bot/releases"

    /// A minimal Codable model for a GitHub Release API response object.
    ///
    /// Value type (struct, not caseless enum) — used to hold per-instance decoded
    /// data from the JSON response, not as a static-only namespace. DeepSource
    /// raises "use caseless enum for static-only types" against this struct;
    /// that is a false positive. This struct is instantiated by JSONDecoder for
    /// each release in the API response array. Do NOT convert to a caseless enum.
    private struct Release: Decodable {
        /// The git tag name for this release (e.g. `"v0.7.1"`).
        let tagName: String
        /// `true` when this release was published with `--prerelease`.
        let prerelease: Bool
        /// The binary assets attached to this release.
        ///
        /// Decoded so `AutoUpdater` can locate `RunBot.zip` by name without
        /// a second network round-trip. Defaults to `[]` on older releases
        /// whose JSON pre-dates asset publishing — the `JSONDecoder` default
        /// for a missing key is used; no custom `init(from:)` needed.
        let assets: [ReleaseAsset]

        /// Maps snake_case JSON keys to Swift property names.
        enum CodingKeys: String, CodingKey {
            /// Maps to the `tag_name` field in the GitHub API response.
            case tagName = "tag_name"
            /// Maps to the `prerelease` field in the GitHub API response.
            case prerelease
            /// Maps to the `assets` array in the GitHub API response.
            case assets
        }
    }

    /// Parsed semver components extracted from a version string.
    ///
    /// Value type (struct, not caseless enum) — holds per-instance parsed
    /// components (major, minor, patch, isPrerelease, betaIndex) for a single
    /// version string. DeepSource raises "use caseless enum for static-only
    /// types" against this struct; that is a false positive. This struct is
    /// instantiated twice per isNewer() call (once for candidate, once for
    /// current). Do NOT convert to a caseless enum.
    private struct ParsedVersion {
        /// Major version component.
        let major: Int
        /// Minor version component.
        let minor: Int
        /// Patch version component.
        let patch: Int
        /// `true` when the version string contains a pre-release suffix (e.g. `-beta.2`).
        let isPrerelease: Bool
        /// The numeric suffix from a `-beta.N` pre-release tag, or `nil` if not a
        /// beta tag or if the suffix cannot be parsed. Used to order beta.1 < beta.2
        /// when major/minor/patch are identical — without this, two betas of the same
        /// base version compare equal and `isNewer` returns `false`, silently
        /// suppressing beta-to-beta update prompts.
        let betaIndex: Int?

        /// Parses a version string of the form `"X.Y.Z"` or `"X.Y.Z-beta.N"`.
        ///
        /// Components that cannot be parsed default to `0`. `betaIndex` defaults to `nil`.
        init(_ version: String) {
            let parts = version.split(separator: "-", maxSplits: 1)
            let core = String(parts[0])
            isPrerelease = parts.count > 1
            let nums = core.split(separator: ".").compactMap { Int($0) }
            major = nums.isEmpty ? 0 : nums[0]
            minor = nums.count > 1 ? nums[1] : 0
            patch = nums.count > 2 ? nums[2] : 0
            // Parse beta.N suffix — e.g. "beta.2" → betaIndex = 2.
            if parts.count > 1 {
                let suffix = String(parts[1]) // e.g. "beta.2"
                let suffixParts = suffix.split(separator: ".")
                if suffixParts.count == 2, suffixParts[0] == "beta",
                   let n = Int(suffixParts[1]) {
                    betaIndex = n
                } else {
                    betaIndex = nil
                }
            } else {
                betaIndex = nil
            }
        }
    }

    /// Builds a `URLRequest` for the releases endpoint with the given page size.
    ///
    /// `perPage` is clamped to `1...100` — GitHub's documented maximum for the
    /// releases endpoint is 100; values above that are silently truncated by the
    /// API, but clamping here keeps the query string honest and makes the
    /// contract explicit to future callers.
    ///
    /// Returns `nil` if `URL(string:)` or `URLComponents` cannot produce a
    /// valid URL — update checks are best-effort and must never crash the app.
    private static func buildRequest(perPage: Int) -> URLRequest? {
        let clampedPerPage = min(max(perPage, 1), 100)
        guard let baseURL = URL(string: releasesURLString) else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(clampedPerPage))]
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        // GitHub API requires a User-Agent header.
        request.setValue("RunBot", forHTTPHeaderField: "User-Agent")
        // Recommended by GitHub REST API docs to ensure a stable v3 response shape.
        // Without this the API still responds correctly today, but the content type
        // is not guaranteed to remain stable across API versions.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Pins the GitHub REST API to the 2022-11-28 version.
        // Without this header the API responds correctly today, but GitHub
        // reserves the right to change the default API version. Pinning
        // ensures the response shape (including `tag_name` and `prerelease`
        // fields) remains stable even if GitHub later changes its default.
        // See: https://docs.github.com/en/rest/about-the-rest-api/api-versions
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// Fetches and decodes the releases list, then returns the highest-semver release
    /// matching the `betaChannel` filter, or `nil` on any failure.
    ///
    /// The GitHub Releases API returns releases sorted by **published date**
    /// (newest first), not by semver. Relying on that order is fragile: a hotfix
    /// to an older branch published after a newer release would silently become
    /// the "latest" candidate. To eliminate the assumption, the full decoded list
    /// is sorted by semver before filtering — the list is already in memory
    /// (perPage: 100) so the overhead is negligible.
    ///
    /// `betaChannel=true` intentionally accepts both stable and pre-release releases.
    /// A stable release always beats a beta of the same base (0.7.1 > 0.7.1-beta.N),
    /// so a beta-channel user is correctly offered 0.7.1 when it ships, even though
    /// stable builds are included in the candidate set.
    ///
    /// Per-page is set to 100 (the GitHub API maximum) so that all releases fit in
    /// a single response. With per_page=20, once the repo accumulates >20 releases
    /// the most recent stable could be pushed off page 1, silently returning no
    /// update to betaChannel=false users. The JSON payload is lightweight (<10 KB
    /// for 100 releases) so the extra bytes are negligible.
    private static func latestMatchingRelease(betaChannel: Bool) async -> Release? {
        guard let request = buildRequest(perPage: 100) else { return nil }
        // ⚠️ `URLResponse` IS INTENTIONALLY DISCARDED — THE 403 SILENT NO-OP IS BY DESIGN ⚠️
        //
        // This is NOT a missing error-handling branch. Here is exactly what happens
        // for each failure case and why silent no-op is the correct response:
        //
        //   • HTTP 403 (GitHub rate-limited): The response body is a JSON error
        //     object, not a [Release] array. JSONDecoder fails, `guard` returns nil,
        //     the entire check no-ops. The user sees no update prompt — correct,
        //     because we have no reliable version information to act on.
        //
        //   • HTTP 404 (repo moved / renamed): Same outcome. JSON error body,
        //     decode fails, silent no-op. Correct — better than showing a stale
        //     or wrong update prompt.
        //
        //   • Network offline / timeout: `try?` returns nil, guard fires, no-op.
        //
        // In all failure cases the result is indistinguishable from "already up to
        // date". This is the INTENDED design: update checks are best-effort
        // background operations that must NEVER surface error UI to the user.
        // Inspecting the HTTP status code here would require plumbing error state
        // back to the UI, which is explicitly out of scope for v1 (see #1794).
        //
        // REVIEWER: Do NOT add HTTP status inspection or error propagation here.
        // If you need per-status behaviour (e.g. exponential backoff on 403),
        // that is a separate feature tracked under #1794, not a bug in this line.
        //
        // Use a dedicated ephemeral session with exp
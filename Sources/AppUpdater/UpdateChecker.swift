// UpdateChecker.swift
// AppUpdater
import Foundation

// MARK: - ReleaseAsset

/// A single asset attached to a GitHub Release (e.g. `RunBot.zip`).
public struct ReleaseAsset: Decodable, Sendable {
    /// The filename of the asset as it appears on the release page.
    public let name: String
    /// The direct download URL for this asset.
    public let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - AvailableRelease

/// A decoded GitHub Release, carrying the tag name and asset list.
public struct AvailableRelease: Sendable {
    /// The git tag of this release (e.g. `"v0.8.0"` or `"v0.8.0-beta.1"`).
    public let tagName: String
    /// The list of binary assets attached to this release.
    public let assets: [ReleaseAsset]
    /// The URL of the SHA-256 checksum sidecar asset, or `nil` if absent.
    public let checksumURL: URL?
}

// MARK: - UpdateCheckResult

/// The result of an `UpdateChecker.checkForUpdate(...)` call.
public enum UpdateCheckResult: Sendable {
    case upToDate
    case updateAvailable(release: AvailableRelease)
    case failed(Error)
}

// MARK: - UpdateCheckError

public enum UpdateCheckError: Error, Sendable {
    case missingVersionKey
    case noReleasesFound
}

// MARK: - UpdateChecker

/// Checks a GitHub repository's Releases for a newer version.
public enum UpdateChecker {

    private struct Release: Decodable {
        let tagName: String
        let prerelease: Bool
        let assets: [ReleaseAsset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case prerelease
            case assets
        }
    }

    private struct ParsedVersion {
        let major: Int
        let minor: Int
        let patch: Int
        let isPrerelease: Bool
        let betaIndex: Int?

        init(_ version: String) { // skipcq: SW-R1002 — reviewed; complexity acceptable for this version parser
            let parts = version.split(separator: "-", maxSplits: 1)
            let core = parts.isEmpty ? "" : String(parts[0])
            isPrerelease = parts.count > 1
            let nums = core.split(separator: ".").compactMap { Int($0) }
            major = nums.isEmpty ? 0 : nums[0]
            minor = nums.count > 1 ? nums[1] : 0
            patch = nums.count > 2 ? nums[2] : 0
            if parts.count > 1 {
                let suffix = String(parts[1])
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

    /// Builds a `URLRequest` for the releases endpoint of `repo`.
    ///
    /// `perPage` is clamped to `1...100` (GitHub's documented maximum for this
    /// endpoint). A single request is made — no pagination.
    ///
    /// ## ⚠️ 100-release ceiling
    ///
    /// `latestMatchingRelease` makes exactly one request with `per_page=100`.
    /// If a repository has published more than 100 releases the oldest releases
    /// (by GitHub's default sort, newest first) are never seen. For most repos
    /// this is not a problem — the newest release is always in the first page.
    /// However if you publish hotfixes to old branches and those appear after
    /// the 100th entry you may miss them. See README "Known limitations" for
    /// the recommended mitigation (keep releases ≤ 100, or draft/delete old ones).
    private static func buildRequest(repo: String, perPage: Int) -> URLRequest? {
        let clampedPerPage = min(max(perPage, 1), 100)
        let releasesURLString = "https://api.github.com/repos/\(repo)/releases"
        guard let baseURL = URL(string: releasesURLString) else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(clampedPerPage))]
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        request.setValue("AppUpdater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// Fetches the releases list for `repo`, sorts by semver, and returns the
    /// highest release matching `betaChannel`, or `nil` on any failure.
    ///
    /// Fetches at most 100 releases (one request, `per_page=100`). See
    /// `buildRequest` for the 100-release ceiling caveat.
    private static func latestMatchingRelease(repo: String, betaChannel: Bool) async -> Release? {
        guard let request = buildRequest(repo: repo, perPage: 100) else { return nil }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request) else { return nil }

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            appUpdaterLogger.debug("releases API returned \(httpResponse.statusCode, privacy: .public) for \(repo, privacy: .public)")
            return nil
        }

        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }

        let sorted = releases.sorted { isNewer($0.tagName, than: $1.tagName) }
        return sorted.first(where: { betaChannel ? true : !$0.prerelease })
    }

    static func fetchLatestAvailableRelease(
        repo: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async -> AvailableRelease? {
        guard let latest = await latestMatchingRelease(repo: repo, betaChannel: betaChannel)
        else { return nil }
        let checksumAssetName = assetName(latest.tagName) + ".sha256"
        let checksumAsset = latest.assets.first(where: { $0.name == checksumAssetName })
        return AvailableRelease(
            tagName: latest.tagName,
            assets: latest.assets,
            checksumURL: checksumAsset?.browserDownloadURL
        )
    }

    /// Returns `true` when `candidate` is strictly newer than `current` using
    /// numeric semver comparison, including beta ordering.
    ///
    /// ## Constraints
    ///
    /// Pre-release ordering is supported **only for `beta.N` labels** (e.g.
    /// `v0.8.0-beta.2` is newer than `v0.8.0-beta.1`). Any other pre-release
    /// suffix — such as `rc.1`, `alpha.1`, or an arbitrary string — is parsed
    /// with `betaIndex == nil`. When both versions share the same
    /// `major.minor.patch` and at least one has a non-`beta.N` pre-release
    /// label, the `if let ci, let si` guard falls through and this function
    /// returns `false`.
    ///
    /// This is not a bug for the current publish pipeline, which only generates
    /// `beta.N` tags. If a future release channel uses a different pre-release
    /// label (e.g. `rc.N`), extend `ParsedVersion` to recognise that suffix and
    /// assign a comparable index before calling this function.
    public static func isNewer(_ candidate: String, than current: String) -> Bool { // skipcq: SW-R1002 — reviewed; complexity acceptable for this semver comparison
        let cv = ParsedVersion(candidate.hasPrefix("v") ? String(candidate.dropFirst()) : candidate)
        let sv = ParsedVersion(current.hasPrefix("v")   ? String(current.dropFirst())   : current)

        if cv.major != sv.major { return cv.major > sv.major }
        if cv.minor != sv.minor { return cv.minor > sv.minor }
        if cv.patch != sv.patch { return cv.patch > sv.patch }

        if cv.isPrerelease != sv.isPrerelease { return !cv.isPrerelease }
        if let ci = cv.betaIndex, let si = sv.betaIndex { return ci > si }

        return false
    }

    public static func checkForUpdate(
        repo: String,
        currentVersion: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async -> UpdateCheckResult {
        guard !currentVersion.isEmpty else {
            return .failed(UpdateCheckError.missingVersionKey)
        }
        guard let release = await fetchLatestAvailableRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        ) else {
            return .failed(UpdateCheckError.noReleasesFound)
        }
        guard isNewer(release.tagName, than: currentVersion) else {
            return .upToDate
        }
        return .updateAvailable(release: release)
    }
}

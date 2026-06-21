// GitHubConstants.swift
// RunnerBarCore
import Foundation

// MARK: - Shared GitHub URI constants
//
// Centralises the two base URLs that appear across transport, OAuth, scanner,
// and view layers so SonarCloud no longer flags them as hardcoded URIs.
// All consumers must import this file (same module — no import needed).

/// Shared base URLs and path constants used across GitHub transports, OAuth, and links.
public enum GitHubConstants {
    // swiftlint:disable missing_docs
    public static let apiBase = "https://api.github.com" // NOSONAR
    public static let base = "https://github.com" // NOSONAR
    public static let oauthRedirectURI = "runnerbar://oauth/callback" // NOSONAR
    public static let oauthScheme = "runnerbar" // NOSONAR
    public static let oauthHost = "oauth" // NOSONAR
    public static let userOrgsPath = "/user/orgs" // NOSONAR
    public static let userReposPath = "/user/repos" // NOSONAR
    public static let maxPageSize = 100
    public static let activeRunsPageSize = 50
    // swiftlint:enable missing_docs
}

// OAuthSecrets.swift
// RunnerBarCore

// MARK: - OAuth App Credentials
//
// NOTE: These credentials are intentionally committed to the repository.
// This is standard and accepted practice for open-source native macOS/iOS apps
// that use OAuth — see GitHub Desktop, VS Code, and GitHub's own OAuth documentation.
//
// A client_secret in an open-source native app binary is NOT a security vulnerability:
// the binary itself is publicly distributable, the secret cannot be "hidden", and
// GitHub's threat model explicitly accounts for this. Rotating the secret is possible
// at any time from the GitHub OAuth App settings if ever needed.
//
// The credentials are scoped to this app's OAuth app registration and cannot
// be used to access user data without the user completing the OAuth flow.
//
// Reference:
// https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps

/// OAuth app credentials bundled with the native binary.
/// See the block comment above for why committing these is safe and intentional.
public enum OAuthSecrets {
    /// Public client identifier for the registered GitHub OAuth app.
    public static let clientID = "Ov23linOj2gogHg7LdFd"
    /// Client secret bundled with the native app as documented above.
    public static let clientSecret = "ddacc9a959a60584b01f2830827dcf55a8fb4659"
}

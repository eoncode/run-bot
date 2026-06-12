// OAuthService.swift
// RunnerBar
import AppKit
import Foundation

// MARK: - OAuthService
//
// Implements the GitHub OAuth Authorization Code flow.
//
// @MainActor ensures all access to `pendingState`, `onCompletion`, and
// `didSignOut` is serialised on the main thread. This matches how AppKit
// delivers application(_:open:) callbacks and how SwiftUI reads `isSignedIn`.
// It also silences the -strict-concurrency warning about non-Sendable
// captures of `self` in DispatchQueue.main.async closures.
//
// Flow:
// 1. signIn() generates a random state nonce, stores it, opens the GitHub
//    authorization URL (with state= param) in the default browser.
// 2. The user clicks "Authorize" on GitHub's consent screen.
// 3. GitHub redirects to runnerbar://oauth/callback?code=...&state=...
// 4. AppDelegate.application(_:open:) catches the URL and calls handleCallback(_:).
// 5. handleCallback verifies the state param matches pendingState (CSRF guard),
//    then exchanges the code for an access token via POST to GitHub.
// 6. Token is saved to Keychain (which also invalidates the token cache).
//    onCompletion is called on the main thread with the actual save result.
//
// Client credentials are in OAuthSecrets.swift — see that file for why they are
// intentionally committed (open-source native app industry standard).

/// Manages OAuthService state and behaviour.
@MainActor
final class OAuthService {
    /// The shared singleton instance.
    static let shared = OAuthService()
    /// Private initialiser — use `shared`.
    private init() {}

    /// The OAuth redirect URI. Must match the value registered in the GitHub OAuth app settings.
    /// Sourced from `GitHubConstants.oauthRedirectURI` — do not duplicate this string instead.
    private let redirectURI = GitHubConstants.oauthRedirectURI
    /// OAuth scopes requested during sign-in.
    ///
    /// - `repo`: Read access to repository runners, workflow runs, and job logs.
    ///   Required for all repo-scoped API calls (`/repos/{owner}/{repo}/actions/*`).
    /// - `read:org`: Read org membership and team info. Required to list org-level
    ///   runners via `/orgs/{org}/actions/runners` for users who are org members
    ///   but not owners.
    /// - `admin:org`: Broader org admin access. Required to call the runners API
    ///   on organisations where the authenticated user is an owner. Without this,
    ///   org-runner fetches return 403 for owner-level accounts.
    /// - `manage_runners:org`: Fine-grained scope (added in 2023) that explicitly
    ///   grants runner management on org level. Requested in addition to `admin:org`
    ///   for forward-compatibility as GitHub narrows older broad scopes.
    /// - `workflow`: Required to trigger and re-run workflow runs via the API.
    ///   Without this, dispatch and re-run actions fail with 403 even when `repo`
    ///   is present.
    ///
    /// Previously only `repo` and `read:org` were requested. The additional scopes
    /// were added because org-runner listing and workflow dispatch were returning 403
    /// for accounts with org-owner or org-admin roles.
    private let scopes = "repo read:org admin:org manage_runners:org workflow"

    // MARK: - OAuth endpoint constants
    /// GitHub OAuth authorisation URL — entry point for the browser-based sign-in flow.
    private let authorizeURL    = "\(GitHubConstants.base)/login/oauth/authorize"
    /// GitHub OAuth token-exchange URL — receives the code and returns the access token.
    private let accessTokenURL  = "\(GitHubConstants.base)/login/oauth/access_token"

    /// CSRF nonce generated in signIn(), verified in handleCallback().
    /// Cleared after use or on sign-out.
    private var pendingState: String?

    /// Called on main thread after sign-in completes. `true` = success.
    /// Register once in SettingsView.onAppearAction — do NOT re-assign in signIn().
    var onCompletion: ((Bool) -> Void)?

    // MARK: - Sign-out multicast
    //
    // Each caller receives its own dedicated AsyncStream via makeSignOutStream().
    // signOut() yields to every registered continuation, restoring the multicast
    // semantics of the old PassthroughSubject without reintroducing Combine.
    // AsyncStream is single-consumer — sharing one stream across multiple Tasks
    // would deliver each event to only one consumer (whichever wakes first).

    /// Registered continuations keyed by UUID — one per active consumer.
    /// Entries are removed automatically via `onTermination` when the consumer's
    /// Task is cancelled (e.g. SettingsView.onDisappear), preventing unbounded growth.
    private var signOutContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Returns a new `AsyncStream<Void>` that fires once per `signOut()` call.
    /// Each call site must request its own stream; the streams are multicasted.
    /// The continuation is removed from the registry when the consumer's Task
    /// is cancelled or the stream is finished.
    func makeSignOutStream() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            signOutContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.signOutContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    // MARK: - Public API

    /// `true` when a GitHub token is stored in Keychain.
    var isSignedIn: Bool { Keychain.token != nil }

    /// Generates a random state nonce, persists it, then opens the GitHub
    /// authorisation URL in the default browser to start the OAuth flow.
    func signIn() {
        let state = UUID().uuidString
        pendingState = state
        var comps = URLComponents(string: authorizeURL)!
        comps.queryItems = [
            .init(name: "client_id",    value: OAuthSecrets.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope",        value: scopes),
            .init(name: "state",        value: state)
        ]
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Clears the stored token and notifies all sign-out consumers.
    func signOut() {
        Keychain.delete()
        for continuation in signOutContinuations.values {
            continuation.yield()
        }
    }

    // MARK: - Callback Handling

    /// Validates the OAuth callback URL and kicks off the token exchange.
    ///
    /// Called by `AppDelegate.application(_:open:)` when the OS delivers the
    /// `runnerbar://oauth/callback` deep-link after GitHub redirects back.
    ///
    /// - Parameter url: The full callback URL including `code` and `state` query params.
    func handleCallback(_ url: URL) {
        log("OAuthService › handleCallback: url=\(url)")
        guard let comps  = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code   = comps.queryItems?.first(where: { $0.name == "code"  })?.value,
              let state  = comps.queryItems?.first(where: { $0.name == "state" })?.value,
              state == pendingState
        else {
            log("OAuthService › handleCallback: missing/mismatched code or state — ignoring")
            return
        }
        pendingState = nil
        log("OAuthService › handleCallback: state OK, code=\(code.prefix(6))… — launching exchangeCode")
        Task { await exchangeCode(code) }
    }

    // MARK: - Sign-out Task

    /// Long-lived Task that listens on the sign-out stream and drives sign-out side-effects.
    ///
    /// Mirrors the same pattern used in `exchangeCode()` where `onCompletion` is
    /// called on the main actor. The Task is stored so callers can cancel it
    /// (e.g. during testing or if AppDelegate needs to tear down the service).
    ///
    /// Retained so the caller can cancel it when the observing scope goes away.
    /// Assign from the site that sets up the sign-out listener (e.g. AppDelegate).
    var signOutTask: Task<Void, Never>?

    // MARK: Token Exchange

    /// Request body for the GitHub OAuth token exchange.
    private struct OAuthTokenRequest: Encodable {
        let client_id: String
        let client_secret: String
        let code: String
    }

    /// Response body from the GitHub OAuth token exchange.
    /// GitHub returns HTTP 200 even on failure, so both `access_token` and `error` are optional.
    private struct OAuthTokenResponse: Decodable {
        let access_token: String?
        let error: String?
        let error_description: String?
    }

    /// POSTs the authorization code to GitHub and saves the returned access token to Keychain.
    private func exchangeCode(_ code: String) async {
        log("OAuthService › exchangeCode — POST to GitHub")
        guard let url = URL(string: accessTokenURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(
            OAuthTokenRequest(
                client_id: OAuthSecrets.clientID,
                client_secret: OAuthSecrets.clientSecret,
                code: code
            )
        )
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let response = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        else {
            log("OAuthService › exchangeCode — network/parse failure, calling onCompletion(false)")
            onCompletion?(false)
            return
        }
        // GitHub returns 200 even on failure; check for an error field before access_token.
        if let errorCode = response.error {
            let desc = response.error_description ?? ""
            log("OAuthService › exchangeCode: GitHub error=\(errorCode) \(desc)")
            onCompletion?(false)
            return
        }
        guard let token = response.access_token, !token.isEmpty else {
            log("OAuthService › exchangeCode: no access_token in response")
            onCompletion?(false)
            return
        }
        // Gate success on whether the token was actually persisted to Keychain.
        // If Keychain.save fails, report failure so the UI does not show signed-in
        // while Keychain.token remains nil and subsequent API calls lack auth.
        log("OAuthService › exchangeCode — got access_token (len=\(token.count)), saving to Keychain")
        let saved = Keychain.save(token)
        log("OAuthService › exchangeCode — Keychain.save result=\(saved), calling onCompletion(\(saved))")
        if !saved { log("OAuthService › exchangeCode: Keychain.save failed") }
        onCompletion?(saved)
    }
}

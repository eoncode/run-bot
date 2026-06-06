// OAuthService.swift
// RunnerBar
import AppKit
import Combine
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
// Client credentials are in Secrets.swift — see that file for why they are
// intentionally committed (open-source native app industry standard).

/// Manages OAuthService state and behaviour.
@MainActor
final class OAuthService {
    /// The shared singleton instance.
    static let shared = OAuthService()
    /// Private initialiser — use `shared`.
    private init() {
        // Singleton — intentionally empty; default property values are sufficient.
    }

    /// The OAuth redirect URI. Must match the value registered in the GitHub OAuth app settings.
    /// Sourced from `GitHubConstants.oauthRedirectURI` — do not duplicate this string inline.
    private let redirectURI = GitHubConstants.oauthRedirectURI
    /// OAuth scopes requested during sign-in.
    private let scopes = "repo read:org admin:org manage_runners:org workflow gist"

    // MARK: - OAuth endpoint constants
    private let authorizeURL    = "\(GitHubConstants.base)/login/oauth/authorize"
    private let accessTokenURL  = "\(GitHubConstants.base)/login/oauth/access_token"

    /// CSRF nonce generated in signIn(), verified in handleCallback().
    private var pendingState: String?

    /// Called on main thread after sign-in completes. `true` = success.
    var onCompletion: ((Bool) -> Void)?

    /// Emits on the main thread after a successful sign-out.
    let didSignOut = PassthroughSubject<Void, Never>()

    // MARK: Sign In

    func signIn() {
        log("OAuthService › signIn — initiating OAuth flow")
        let state = UUID().uuidString
        pendingState = state
        guard var comps = URLComponents(string: authorizeURL) else {
            log("OAuthService › signIn: malformed authorizeURL — aborting")
            pendingState = nil
            onCompletion?(false)
            return
        }
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Secrets.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = comps.url else {
            log("OAuthService › signIn: failed to build authorization URL — aborting")
            pendingState = nil
            onCompletion?(false)
            return
        }
        log("OAuthService › signIn — opening browser for OAuth")
        NSWorkspace.shared.open(url)
    }

    // MARK: Sign Out

    func signOut() {
        log("OAuthService › signOut — called, pendingState=\(pendingState != nil ? "set" : "nil")")
        pendingState = nil
        let deleted = Keychain.delete()
        log("OAuthService › signOut — Keychain.delete result=\(deleted)")
        if deleted {
            log("OAuthService › signOut — emitting didSignOut")
            didSignOut.send()
        } else {
            log("OAuthService › signOut: Keychain.delete failed — sign-out suppressed to prevent ghost sign-in")
        }
    }

    // MARK: Callback Handler

    func handleCallback(_ url: URL) {
        log("OAuthService › handleCallback — url=\(url.absoluteString)")
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            log("OAuthService › handleCallback — missing code param, calling onCompletion(false)")
            onCompletion?(false)
            return
        }
        guard let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value else {
            log("OAuthService › handleCallback: no state param in redirect URL")
            pendingState = nil
            onCompletion?(false)
            return
        }
        guard returnedState == pendingState else {
            log("OAuthService › handleCallback: state mismatch — possible CSRF attempt, rejecting")
            pendingState = nil
            onCompletion?(false)
            return
        }
        log("OAuthService › handleCallback — state OK, exchanging code")
        pendingState = nil
        Task { await exchangeCode(code) }
    }

    // MARK: Token Exchange

    private func exchangeCode(_ code: String) async {
        log("OAuthService › exchangeCode — POST to GitHub")
        guard let url = URL(string: accessTokenURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": Secrets.clientID,
            "client_secret": Secrets.clientSecret,
            "code": code
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("OAuthService › exchangeCode — network/parse failure, calling onCompletion(false)")
            onCompletion?(false)
            return
        }
        if let errorCode = json["error"] as? String {
            let desc = json["error_description"] as? String ?? ""
            log("OAuthService › exchangeCode: GitHub error=\(errorCode) \(desc)")
            onCompletion?(false)
            return
        }
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            log("OAuthService › exchangeCode: no access_token in response — keys=\(json.keys.sorted())")
            onCompletion?(false)
            return
        }
        log("OAuthService › exchangeCode — got access_token (len=\(token.count)), saving to Keychain")
        let saved = Keychain.save(token)
        log("OAuthService › exchangeCode — Keychain.save result=\(saved), calling onCompletion(\(saved))")
        if !saved { log("OAuthService › exchangeCode: Keychain.save failed") }
        onCompletion?(saved)
    }
}

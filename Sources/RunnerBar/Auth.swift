import Foundation

/// Returns a GitHub personal access token from the first available source.
///
/// Priority order:
/// 1. Keychain — OAuth token stored by OAuthService after the user signs in via the native flow.
/// 2. `gh auth token` — fallback for existing users who authenticated via the gh CLI.
///    Keeps working zero-friction during and after the transition to native OAuth.
/// 3. `GH_TOKEN` environment variable — useful in CI or scripted contexts.
/// 4. `GITHUB_TOKEN` environment variable — fallback for Actions-style environments.
///
/// Returns `nil` if no token is available from any source.
func githubToken() -> String? {
    // 1. Keychain — preferred; set by OAuthService after native OAuth sign-in
    if let token = Keychain.token { return token }

    // 2. gh CLI fallback — existing users keep working without re-authenticating
    if let ghPath = ghBinaryPath() {
        let result = shell("\(ghPath) auth token", timeout: 10)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty && !result.hasPrefix("error") { return result }
    }

    // 3–4. CI / environment variable fallbacks
    for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
        if let token = ProcessInfo.processInfo.environment[key], !token.isEmpty { return token }
    }

    return nil
}

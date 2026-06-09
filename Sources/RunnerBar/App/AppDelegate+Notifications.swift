// AppDelegate+Notifications.swift
// RunnerBar

import AppKit

extension AppDelegate {

    // MARK: - OAuth URL callback

    /// Handles the OAuth callback URL (`runnerbar://oauth/…`) delivered by the OS
    /// after the user authorises the GitHub OAuth flow in the browser.
    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: {
            $0.scheme == GitHubConstants.oauthScheme && $0.host == GitHubConstants.oauthHost
        }) else { return }
        OAuthService.shared.handleCallback(url)
    }
}

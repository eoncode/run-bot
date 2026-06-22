// AppDelegate+StoreSetup.swift
// RunnerBar

import AppKit

/// AppDelegate extension wiring app-lifecycle callbacks to store and service setup.
extension AppDelegate {

    // MARK: - App lifecycle

    /// Sets activation policy during UI tests so XCTest can see windows.
    /// - Parameter _: The notification (unused).
    func applicationWillFinishLaunching(_ _: Notification) {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Entry point after launch. Configures the GitHub API clients, builds the
    /// status-bar item, and constructs the NSPopover panel.
    /// - Parameter _: The notification (unused).
    func applicationDidFinishLaunching(_ _: Notification) {
        log("AppDelegate › applicationDidFinishLaunching — START")
        configureGHToken { githubToken() }
        // Wire all three shim transports directly to sharedGitHubTransport,
        // eliminating the intermediate hop through module-level free-function shims.
        // The token is resolved per-call via sharedGitHubTransport's default
        // tokenProvider (githubTokenCore()), which reads the box configured above.
        configureGHAPI { endpoint in
            await sharedGitHubTransport.apiAsync(endpoint)
        }
        configureGHRaw { endpoint in
            await sharedGitHubTransport.raw(endpoint)
        }
        // Both `endpoint` and `timeout` must be forwarded so callers that pass
        // a custom timeout via ghAPIPaginated(endpoint, timeout:) are not silently
        // overridden by apiPaginated’s 60-second default.
        configureGHAPIPaginated { endpoint, timeout in
            await sharedGitHubTransport.apiPaginated(endpoint, timeout: timeout)
        }
        setupStatusItem()
        setupPanel()
        setupSignOutSubscription()
    }
}

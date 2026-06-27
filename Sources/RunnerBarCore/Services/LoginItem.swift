// LoginItem.swift
// RunnerBarCore
import ServiceManagement

/// Manages the app's launch-at-login registration via `SMAppService`.
///
/// Moved from `RunnerBar` to `RunnerBarCore` in #1623.
public enum LoginItem {
    /// `true` when the app is registered to launch at login.
    /// Checks the live `SMAppService` status — reflects changes made
    /// outside the app (e.g. via System Settings > General > Login Items).
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters launch-at-login based on `enabled`.
    /// Called from the login-item toggle in `SettingsView` via the two-argument
    /// `onChange(of:)` form, which supplies the new toggle value directly.
    ///
    /// - Returns: `true` if the operation succeeded, `false` if `SMAppService`
    ///   threw an error. The caller is responsible for reverting UI state on `false`.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            log("[RunnerBar] LoginItem.setEnabled(\(enabled)) failed: \(error)", category: .services)
            return false
        }
    }
}

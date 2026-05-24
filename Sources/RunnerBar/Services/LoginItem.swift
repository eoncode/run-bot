// LoginItem.swift
// RunnerBar
import ServiceManagement

/// Manages the app's launch-at-login registration via `SMAppService`.
enum LoginItem {
    // swiftlint:disable missing_docs
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
    // swiftlint:enable missing_docs

    /// Registers or unregisters launch-at-login based on `enabled`.
    /// Called by `PopoverMainView` from the two-argument `onChange(of:)` form,
    /// which supplies the new toggle value directly.
    /// Errors are logged to stderr but otherwise swallowed — failure is non-fatal
    /// since the checkbox UI will simply reflect the unchanged state on next read.
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("[RunnerBar] LoginItem.setEnabled(\(enabled)) failed: \(error)")
        }
    }
}

// TerminalLauncher.swift
// RunnerBar
import Foundation

/// Opens a Terminal.app window and runs a shell command via AppleScript (`do script`).
///
/// # Why this lives in the app target
/// `NSAppleScript` drives a UI application (Terminal.app) and requires a running macOS
/// user session — it is an app-layer concern by definition. Moving it to `RunnerBarCore`
/// would break Linux builds and make the library untestable in isolation.
///
/// If Core ever needs to *trigger* terminal launches, introduce a protocol there
/// (e.g. `TerminalLaunchable`) and keep this concrete `NSAppleScript` implementation
/// here as the production conformance — the same pattern used for other AppKit-bound
/// services throughout the codebase.
///
/// Uses `NSAppleScript` — requires no entitlements on an unsandboxed app.
/// Backslashes, double quotes, and newlines in the command are escaped before
/// embedding in the AppleScript string. Tracked in #546.
enum TerminalLauncher {
    /// Opens Terminal.app and runs `command` in a new window.
    static func open(command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let src = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        if NSAppleScript(source: src)?.executeAndReturnError(&error) == nil {
            log("TerminalLauncher › AppleScript error: \(error ?? [:])")
        }
    }
}

// TerminalLauncher.swift
// RunnerBar
import Foundation

// MARK: - TerminalLauncher

// #546: Opens a normal Terminal.app window and runs the given command via AppleScript.
//
// Uses NSAppleScript + `do script` — requires no entitlements on an unsandboxed app.
// Escapes backslashes, double quotes, and newlines before embedding in the AppleScript string.
/// Launches commands in Terminal.app via AppleScript's `do script` directive.
/// Handles escaping of backslashes, double-quotes, and newlines so arbitrary
/// shell commands are passed through correctly.
enum TerminalLauncher {
    /// Opens a new Terminal.app window and executes `command` inside it.
    /// Backslashes, double-quotes, and newlines in `command` are escaped
    /// before embedding in the AppleScript source string.
    /// Logs an error via `log()` if the AppleScript fails to execute.
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

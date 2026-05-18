import Foundation

/// Executes shell commands synchronously.
enum Shell {
    /// Result of a shell command execution.
    struct Result {
        /// Standard output text.
        let output: String
        /// Exit code returned by the process.
        let exitCode: Int32
    }

    /// Runs `command` in `/bin/zsh -c` and returns the trimmed output + exit code.
    @discardableResult
    // swiftlint:disable:next function_body_length
    static func run(_ command: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return Result(output: error.localizedDescription, exitCode: -1)
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)
        let output = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Result(output: output, exitCode: process.terminationStatus)
    }
}

// MARK: - Backward-compatibility shim
// Legacy call-sites use shell("cmd", timeout: N) -> String.
// Delegates to Shell.run(_:); the timeout parameter is accepted but not
// enforced (Shell.run uses waitUntilExit which is sufficient for existing callers).
@discardableResult
func shell(_ command: String, timeout: TimeInterval = 20) -> String {
    Shell.run(command).output
}

// ReRunFailedButton.swift
// RunnerBar
import SwiftUI

// MARK: - ReRunFailedButton
// periphery:ignore
/// Top-bar "Re-run failed jobs" button.
/// Mirrors ReRunButton's phase-machine pattern but calls the
/// GitHub "rerun-failed-jobs" endpoint instead of the full rerun endpoint.
///
/// GitHub API: POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs
///
/// idle (exclamationmark.arrow.clockwise + "Re-run failed") →
/// loading (spinner + "Running…") →
/// done (✓ + "Done", 1.5 s) OR failed (✗ + "Failed", 1.5 s) → idle
/// On macOS 26+ the idle button uses .glassEffect; on macOS < 26 it is plain.
struct ReRunFailedButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is completely hidden and takes no layout space.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    // MARK: - Phase
    enum Phase {
        case idle, loading, done, failed
    }

    // MARK: - Body
    var body: some View {
        Group {
            switch phase {
            case .idle:
                if !isDisabled { idleButton }
            case .loading:
                ButtonPhaseView(phase: .loading)
            case .done:
                ButtonPhaseView(phase: .done)
            case .failed:
                ButtonPhaseView(phase: .failed)
            }
        }
    }

    // MARK: - Idle button
    @ViewBuilder
    private var idleButton: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "exclamationmark.arrow.clockwise")
                .font(.caption)
            Text("Re-run failed")
                .font(.caption)
                .fixedSize()
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)

        if #available(macOS 26, *) {
            Button(action: startRerun) { label }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                )
                .help("Re-run only the failed and cancelled jobs in this workflow run")
        } else {
            Button(action: startRerun) { label }
                .buttonStyle(.plain)
                .help("Re-run only the failed and cancelled jobs in this workflow run")
        }
    }

    // MARK: - Actions
    private func startRerun() {
        guard phase == .idle else { return }
        phase = .loading
        action { success in
            DispatchQueue.main.async {
                phase = success ? .done : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    phase = .idle
                }
            }
        }
    }
}

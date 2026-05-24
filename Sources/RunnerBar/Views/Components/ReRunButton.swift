// ReRunButton.swift
// RunnerBar
import SwiftUI

// MARK: - ReRunButton
// periphery:ignore
/// Top-bar re-run button.
/// idle (arrow.clockwise + "Re-run") ->
/// loading (spinner + "Running...") ->
/// done (checkmark + "Done", 1.5 s) OR failed (cross + "Failed", 1.5 s) -> idle
/// On macOS 26+ the idle button uses .glassEffect; on macOS < 26 it is plain.
struct ReRunButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is completely hidden and takes no layout space.
    var isDisabled: Bool = false

    /// Current phase of the button lifecycle.
    @State private var phase: Phase = .idle

    // MARK: - Phase
    /// Visual states of the re-run button lifecycle.
    enum Phase {
        /// Normal tappable state.
        case idle
        /// Spinner shown while the re-run request is in-flight.
        case loading
        /// Green checkmark shown for 1.5 s after success.
        case done
        /// Red cross shown for 1.5 s after failure.
        case failed
    }

    // MARK: - Body
    /// Renders idle button or delegates to `ButtonPhaseView` for active states.
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
    /// The idle-state button, styled with glass on macOS 26+ or plain on earlier OS.
    @ViewBuilder
    private var idleButton: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
                .font(.caption)
            Text("Re-run")
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
        } else {
            Button(action: startRerun) { label }
                .buttonStyle(.plain)
        }
    }

    // MARK: - Actions
    /// Transitions the button to `.loading`, invokes `action`, then transitions
    /// to `.done` or `.failed` before resetting to `.idle` after 1.5 s.
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

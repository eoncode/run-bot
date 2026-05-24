// ButtonPhaseView.swift
// RunnerBar
import SwiftUI

// MARK: - ButtonPhaseView
/// Shared non-idle phase renderer used by `ReRunButton`, `ReRunFailedButton`,
/// and `CancelButton`.
///
/// Renders one of three states:
/// - `.loading` → spinner + label
/// - `.done`    → green checkmark + "Done" (shown for 1.5 s)
/// - `.failed`  → red cross + "Failed" (shown for 1.5 s)
///
/// The `.idle` state is intentionally excluded; each button owns its own
/// idle appearance and action.
///
/// ❌ NO .glassEffect here — ButtonPhaseView is an inline loading indicator,
/// not a floating element. Apple HIG: no glass on inline row content.
struct ButtonPhaseView: View {
    /// The active non-idle phase to render.
    enum Phase {
        case loading, done, failed
    }

    let phase: Phase

    var body: some View {
        switch phase {
        case .loading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Running\u{2026}")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.green)
                Text("Done")
                    .font(.caption)
                    .foregroundColor(.green)
                    .fixedSize()
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.red)
                Text("Failed")
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize()
            }
        }
    }
}

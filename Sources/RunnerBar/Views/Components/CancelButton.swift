// CancelButton.swift
// RunnerBar
import SwiftUI

// MARK: - CancelButton
// periphery:ignore
/// Top-bar cancel button used in JobDetailView and StepLogView.
/// States: idle → loading → done (1.5 s) or failed (1.5 s) → idle.
struct CancelButton: View {
    /// Called on tap. Must invoke completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is rendered at reduced opacity and cannot be tapped.
    var isDisabled: Bool = false

    /// The phase property.
    @State private var phase: ButtonPhaseView.Phase?

    // MARK: - Body
    /// Renders idle cancel button or delegates to `ButtonPhaseView` for active states.
    var body: some View {
        Group {
            if let phase {
                ButtonPhaseView(phase: phase)
            } else {
                idleButton
            }
        }
    }

    // MARK: - Idle button
    /// Renders the idle state: Liquid Glass button on Swift 6.2+ / macOS 26+,
    /// plain button on older SDKs.
    @ViewBuilder private var idleButton: some View {
        #if swift(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer {
                Button(action: startCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                        Text("Cancel")
                            .font(.caption)
                            .fixedSize()
                    }
                    .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous))
            }
        } else {
            Button(action: startCancel) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                    Text("Cancel")
                        .font(.caption)
                        .fixedSize()
                }
                .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
        #else
        Button(action: startCancel) {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                Text("Cancel")
                    .font(.caption)
                    .fixedSize()
            }
            .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        #endif
    }

    // MARK: - Actions
    /// Performs the cancel action: transitions to `.loading`, invokes `action`,
    /// then transitions to `.done` or `.failed` before resetting to idle after 1.5 s.
    private func startCancel() {
        guard phase == nil else { return }
        phase = .loading
        action { success in
            DispatchQueue.main.async {
                self.phase = success ? .done : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.phase = nil
                }
            }
        }
    }
}

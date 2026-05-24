// LogCopyButton.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - LogCopyButton
/// Button that copies the full step log to the clipboard.
/// Uses GlassCard for its surface, matching the Liquid Glass language.
struct LogCopyButton: View {
    @ObservedObject var logVM: StepLogViewModel
    @State private var copied = false

    var body: some View {
        Button(action: copyLog) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .animation(.easeInOut(duration: 0.15), value: copied)
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassCard(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .disabled(logVM.lines.isEmpty)
    }

    private func copyLog() {
        let text = logVM.lines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
    }
}

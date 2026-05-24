// StepLogView.swift
// RunnerBar
// swiftlint:disable file_length type_body_length
import RunnerBarCore
import SwiftUI

// MARK: - StepLogView
/// Full-window view that streams and displays the log output for a single job step.
struct StepLogView: View {
    let job: ActiveJob
    let step: JobStep
    @ObservedObject var store: RunnerViewModel
    let onDismiss: () -> Void

    @StateObject private var logVM: StepLogViewModel
    @State private var searchText = ""
    @State private var wrapLines = false

    init(job: ActiveJob, step: JobStep, store: RunnerViewModel, onDismiss: @escaping () -> Void) {
        self.job = job
        self.step = step
        self.store = store
        self.onDismiss = onDismiss
        _logVM = StateObject(wrappedValue: StepLogViewModel(job: job, step: step, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logBody
        }
        .glassCard()
        .frame(minWidth: 680, minHeight: 400)
        .onAppear { logVM.load() }
        .onDisappear { logVM.cancel() }
    }

    // MARK: - Toolbar
    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Back")

            VStack(alignment: .leading, spacing: 1) {
                Text(step.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(job.name)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("Wrap", isOn: $wrapLines)
                .toggleStyle(.button)
                .controlSize(.small)

            SearchField(text: $searchText, placeholder: "Filter\u2026")
                .frame(width: 160)

            LogCopyButton(logVM: logVM)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassSection()
    }

    // MARK: - Log body
    @ViewBuilder
    private var logBody: some View {
        if logVM.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = logVM.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogTextView(
                lines: filteredLines,
                wrapLines: wrapLines
            )
            .background(Color.clear)
        }
    }

    private var filteredLines: [StepLogLine] {
        guard !searchText.isEmpty else { return logVM.lines }
        return logVM.lines.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }
}
// swiftlint:enable file_length type_body_length

import AppKit
import SwiftUI

// MARK: - RunnerDetailView
// Navigation level: SettingsView (runner row tap) → RunnerDetailView ← this view
//
// Displays a read-only info block for a locally-installed runner.
// Editable config fields and the Danger Zone are added in subsequent issues (#492, #493).

struct RunnerDetailView: View {
    let runner: RunnerModel
    let onBack: () -> Void

    // Kept as @State so Start/Stop can optimistically update the row.
    @State private var isRunning: Bool
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared

    init(runner: RunnerModel, onBack: @escaping () -> Void) {
        self.runner = runner
        self.onBack = onBack
        self._isRunning = State(initialValue: runner.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    infoSection
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .onChange(of: localRunnerStore.runners) { updated in
            if let fresh = updated.first(where: { $0.id == runner.id }) {
                isRunning = fresh.isRunning
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.caption)
                    Text("Settings").font(.caption)
                }
                .foregroundColor(Color.rbTextSecondary)
                .fixedSize()
            }
            .buttonStyle(.plain)

            Spacer()

            // Status dot + name
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(runner.runnerName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            // Start / Stop
            if isRunning {
                Button(action: stopRunner) {
                    Text("Stop").font(.caption2)
                }
                .buttonStyle(.bordered)
                .help("Stop runner service")
            } else {
                Button(action: startRunner) {
                    Text("Start").font(.caption2)
                }
                .buttonStyle(.bordered)
                .help("Start runner service")
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Runner Info")
            infoCard {
                // GitHub URL
                if let url = runner.gitHubUrl {
                    infoRow(label: "GitHub URL", value: url, copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                // Agent ID
                if let agentId = runner.agentId {
                    infoRow(label: "Agent ID", value: String(agentId))
                    Divider().padding(.leading, RBSpacing.md)
                }
                // OS / Architecture
                let osArch = [runner.platform, runner.platformArchitecture]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
                if !osArch.isEmpty {
                    infoRow(label: "OS / Arch", value: osArch)
                    Divider().padding(.leading, RBSpacing.md)
                }
                // Runner version
                if let version = runner.agentVersion {
                    infoRow(label: "Version", value: version)
                    Divider().padding(.leading, RBSpacing.md)
                }
                // Install path
                if let installPath = runner.installPath {
                    infoRow(label: "Install path", value: installPath, copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                // Work folder
                infoRow(label: "Work folder", value: runner.workFolder ?? "_work")
                Divider().padding(.leading, RBSpacing.md)
                // Ephemeral mode
                infoRow(label: "Ephemeral", value: runner.isEphemeral ? "Yes" : "No")
                // Labels
                if !runner.labels.isEmpty {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Labels", value: runner.labels.joined(separator: ", "))
                }
                // Runner group (populated via GitHub API by RunnerStatusEnricher)
                if let group = runner.runnerGroup {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Runner group", value: group)
                }
                Divider().padding(.leading, RBSpacing.md)
                // Status
                infoRow(label: "Status", value: runner.displayStatus)
            }
        }
    }

    // MARK: - Sub-view helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader)
            .foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: RBRadius.small)
                .fill(Color.rbSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.small)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, RBSpacing.md)
        .padding(.bottom, 8)
    }

    private func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color.rbTextPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 7)
    }

    // MARK: - Dot color

    private var dotColor: Color {
        switch runner.statusColor {
        case .running: return Color.rbSuccess
        case .busy:    return Color.rbWarning
        case .idle:    return Color.rbTextTertiary
        case .offline: return Color.rbDanger
        }
    }

    // MARK: - Start / Stop

    private func startRunner() {
        isRunning = true
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.start(runner: runner)
            DispatchQueue.main.async {
                switch result {
                case .success: break
                default:
                    isRunning = false
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }

    private func stopRunner() {
        isRunning = false
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.stop(runner: runner)
            DispatchQueue.main.async {
                switch result {
                case .success: break
                default:
                    isRunning = true
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }
}

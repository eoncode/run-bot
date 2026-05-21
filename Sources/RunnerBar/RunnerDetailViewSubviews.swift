import AppKit
import SwiftUI

// MARK: - RunnerDetailView Subviews
// Section views extracted from RunnerDetailView to keep type_body_length compliant.

extension RunnerDetailView {

    // MARK: - Header

    var headerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.caption)
                    Text("Settings").font(.caption)
                }
                .foregroundColor(Color.rbTextSecondary)
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(runner.runnerName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isRunning {
                    Button(action: stopRunner) { Text("Stop").font(.caption2) }
                        .buttonStyle(.bordered).help("Stop runner service")
                } else {
                    Button(action: startRunner) { Text("Start").font(.caption2) }
                        .buttonStyle(.bordered).help("Start runner service")
                }
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    var dotColor: Color {
        isRunning ? Color.rbSuccess : Color.rbDanger
    }

    // MARK: - Info Section

    var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Runner Info")
            infoCard {
                if let url = runner.gitHubUrl {
                    infoRow(label: "GitHub URL", value: url, copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                infoRow(label: "Work folder", value: runner.workFolder ?? "_work")
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Ephemeral", value: runner.isEphemeral ? "Yes" : "No")
                if !displayOsArch.isEmpty {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "OS / Arch", value: displayOsArch)
                }
                if !displayVersion.isEmpty {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Version", value: displayVersion)
                }
                Divider().padding(.leading, RBSpacing.md)
                statusRow
            }
        }
    }

    var statusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Status")
                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading).fixedSize()
            HStack(spacing: 4) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(displayStatus)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.rbTextPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 7)
    }

    // MARK: - Config Section

    var configSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Configuration")
            infoCard {
                configRow(
                    label: "Labels",
                    placeholder: "comma-separated",
                    text: $labelsText,
                    saveState: labelsSaveState,
                    onSave: saveLabels
                )
                Divider().padding(.leading, RBSpacing.md)
                configRow(
                    label: "Work folder",
                    placeholder: "_work",
                    text: $workFolderText,
                    saveState: workFolderSaveState,
                    onSave: saveWorkFolder
                )
                Divider().padding(.leading, RBSpacing.md)
                HStack(spacing: 8) {
                    Text("Autoupdate")
                        .font(.system(size: 12))
                        .foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading)
                        .fixedSize()
                    Spacer()
                    Toggle("", isOn: $autoUpdate)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: autoUpdate) { _ in saveAutoUpdate() }
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 8)
                Divider().padding(.leading, RBSpacing.md)
                Text("Proxy")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.rbTextTertiary)
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("URL")
                        .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading).fixedSize()
                    TextField("http://proxy:8080", text: $proxyUrl)
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("Username")
                        .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading).fixedSize()
                    TextField("username", text: $proxyUser)
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("Password")
                        .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading).fixedSize()
                    SecureField("password", text: $proxyPassword)
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Spacer()
                    saveButton(state: proxySaveState, action: saveProxy)
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 6)
                saveStateRow(proxySaveState, restartNote: true)
            }
        }
    }

    func configRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        saveState: SaveState,
        onSave: @escaping () -> Void,
        secure: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize()
            if secure {
                SecureField(placeholder, text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
            } else {
                TextField(placeholder, text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
            }
            saveButton(state: saveState, action: onSave)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - Danger Zone

    var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(Color.rbDanger)
                Text("Danger Zone")
                    .font(RBFont.sectionHeader)
                    .foregroundColor(Color.rbDanger)
                Spacer()
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) {
                dangerActionRow(
                    action: .remove,
                    description: "Permanently de-registers and removes this runner."
                )
            }
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small)
                    .fill(Color.rbDanger.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: RBRadius.small)
                            .strokeBorder(Color.rbDanger.opacity(0.25), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 8)
        }
    }

    func dangerActionRow(action: DangerAction, description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(action.destructive ? Color.rbDanger : Color.rbTextPrimary)
                Text(description)
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // swiftlint:disable:next multiple_closures_with_trailing_closure
            Button(action: { triggerDangerAction(action) }) {
                Text(action.title)
                    .font(.caption2)
                    .foregroundColor(action.destructive ? Color.rbDanger : Color.rbTextPrimary)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    func dangerActionSheet(_ action: DangerAction) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title).font(.headline).padding(.top, 4)
            Text("This will de-register \"\(runner.runnerName)\" from GitHub and remove it from the list. The runner binary remains on disk.")
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
            if case .failure(let msg) = dangerActionState {
                Text(msg).font(.caption2).foregroundColor(Color.rbDanger)
            }
            if dangerActionState == .success {
                Text("Done.").font(.caption2).foregroundColor(Color.rbSuccess)
            }
            Divider()
            HStack {
                Button("Cancel") {
                    pendingDangerAction = nil
                    dangerActionState = .idle
                }
                .buttonStyle(.plain)
                .foregroundColor(Color.rbTextSecondary)
                Spacer()
                if dangerActionState == .saving {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button(action.confirmLabel) { executeDangerAction(action) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.rbDanger)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    // MARK: - Reusable helpers

    @ViewBuilder
    func saveButton(state: SaveState, action: @escaping () -> Void) -> some View {
        switch state {
        case .saving:
            ProgressView().scaleEffect(0.6).frame(width: 28, height: 20)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13)).foregroundColor(Color.rbSuccess).frame(width: 28)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13)).foregroundColor(Color.rbDanger).frame(width: 28)
        default:
            Button(action: action) { Text("Save").font(.caption2) }.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func saveStateRow(_ state: SaveState, restartNote: Bool) -> some View {
        if restartNote, state == .success {
            Text("Changes take effect after the next runner restart.")
                .font(.caption2).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
        } else if case .failure(let msg) = state {
            Text(msg).font(.caption2).foregroundColor(Color.rbDanger)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
        }
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

    func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small)
                    .fill(Color.rbSurfaceElevated)
                    .overlay(RoundedRectangle(cornerRadius: RBRadius.small)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
            )
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 8)
    }

    func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading).fixedSize()
            Text(value)
                .font(.system(size: 12, design: .monospaced)).foregroundColor(Color.rbTextPrimary)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                // swiftlint:disable:next multiple_closures_with_trailing_closure
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain).help("Copy to clipboard")
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
    }
}

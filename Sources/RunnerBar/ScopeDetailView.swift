import SwiftUI

// MARK: - ScopeDetailView
// Navigation level: SettingsView (scope row tap) → ScopeDetailView
//
// #499: Nav shell + wiring
// #513: Simplified — alias, polling, notifications sections removed.
//       Enable toggle moved from header into its own Monitoring section.
//       Monitoring row removed from Scope Info card.
// #539: Layout improvements -- section labels, card structure aligned with spec.
// #544: Failure Hook section added between Monitoring and Danger Zone.

struct ScopeDetailView: View {
    let scopeEntry: ScopeEntry
    let onBack: () -> Void

    @ObservedObject private var scopeStore = ScopeStore.shared
    @State private var showHookSheet = false
    @State private var hookEnabled: Bool

    init(scopeEntry: ScopeEntry, onBack: @escaping () -> Void) {
        self.scopeEntry = scopeEntry
        self.onBack = onBack
        _hookEnabled = State(initialValue: ScopeSettingsStore.failureHookEnabled(for: scopeEntry.scope))
    }

    // Live entry from store so toggle reflects current state.
    private var liveEntry: ScopeEntry? {
        scopeStore.entries.first(where: { $0.id == scopeEntry.id })
    }
    private var isEnabled: Bool { liveEntry?.isEnabled ?? scopeEntry.isEnabled }
    private var scope: String { scopeEntry.scope }
    private var isRepo: Bool { scope.contains("/") }

    private var hookCommand: String? {
        ScopeSettingsStore.failureHookCommand(for: scope)
    }

    /// GitHub URL for this scope: https://github.com/<org>/<repo> or https://github.com/<org>
    private var gitHURL: URL? {
        URL(string: "https://github.com/\(scope)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    infoSection
                    monitoringSection
                    failureHookSection
                    dangerSection
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .sheet(isPresented: $showHookSheet) {
            FailureHookCommandSheet(scope: scope) { showHookSheet = false }
        }
    }

    // MARK: - Header
    // #517: Toggle removed from header — header is now clean nav only.
    // #539: Header now shows Repo/Org badge + display name on right.

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

            HStack(spacing: 6) {
                Text(isRepo ? "Repo" : "Org")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.rbSurfaceElevated))
                    .overlay(Capsule().strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))

                Text(ScopeSettingsStore.displayName(for: scope))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Scope Info
    // #518: Monitoring row removed — covered by the Monitoring section toggle below.
    // #539: Scope row includes copy button; Type row label aligned.

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Scope Info")
            infoCard {
                infoRow(label: "Scope", value: scope, copyable: true)
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Type", value: isRepo ? "Repository" : "Organisation")
                if let url = gitHURL {
                    Divider().padding(.leading, RBSpacing.md)
                    HStack(alignment: .top, spacing: 8) {
                        Text("GitHub")
                            .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading).fixedSize()
                        // swiftlint:disable:next multiple_closures_with_trailing_closure
                        Button(action: { NSWorkspace.shared.open(url) }) {
                            HStack(spacing: 4) {
                                Text("Open on GitHub")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.rbAccent)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.rbAccent)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(url.absoluteString)
                        Spacer()
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                }
            }
        }
    }

    // MARK: - Monitoring
    // #517: Enable toggle moved here from the header bar, with clear label + description.
    // #539: Description text updated for clarity.

    private var monitoringSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Monitoring")
            infoCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitor this scope")
                            .font(.system(size: 12, weight: .medium))
                        Text(isEnabled
                             ? "RunnerBar actively polls this scope for runner status."
                             : "Polling is paused. No runner data will be fetched for this scope.")
                            .font(.caption2)
                            .foregroundColor(Color.rbTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isEnabled },
                        set: { ScopeStore.shared.setEnabled(scopeEntry.id, $0); RunnerStore.shared.start() }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color.rbSuccess)
                    .labelsHidden()
                    .help(isEnabled ? "Pause monitoring this scope" : "Resume monitoring")
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
            }
        }
    }

    // MARK: - Failure Hook (#544)

    private var failureHookSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Failure Hook")
            infoCard {
                // Toggle row
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Call this terminal call on failure detection")
                            .font(.system(size: 12, weight: .medium))
                        Text("This will call terminal with a call of your choosing. Can be used for AI auto-recovery.")
                            .font(.caption2)
                            .foregroundColor(Color.rbTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { hookEnabled },
                        set: { newVal in
                            hookEnabled = newVal
                            ScopeSettingsStore.setFailureHookEnabled(newVal, for: scope)
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color.rbSuccess)
                    .labelsHidden()
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)

                Divider().padding(.leading, RBSpacing.md)

                // Command row — tappable, shows current command or placeholder
                // swiftlint:disable:next multiple_closures_with_trailing_closure
                Button(action: { showHookSheet = true }) {
                    HStack(spacing: 8) {
                        Text("Command")
                            .font(.system(size: 12))
                            .foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading)
                            .fixedSize()
                        if let cmd = hookCommand, !cmd.isEmpty {
                            Text(cmd)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color.rbTextPrimary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("Tap to set a command…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color.rbTextTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(Color.rbTextTertiary)
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Danger Zone
    // #539: Description copy updated to match issue spec.

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Danger Zone")
            infoCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove scope")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.rbDanger)
                        Text("Stops monitoring this scope. Runners already discovered are not affected.")
                            .font(.caption2).foregroundColor(Color.rbTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    // swiftlint:disable:next multiple_closures_with_trailing_closure
                    Button(action: removeScope) {
                        Text("Remove").font(.caption2).foregroundColor(Color.rbDanger)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
            }
        }
    }

    // MARK: - Actions

    private func removeScope() {
        ScopeSettingsStore.cleanUp(scope: scope)
        ScopeStore.shared.remove(id: scopeEntry.id)
        RunnerStore.shared.start()
        onBack()
    }

    // MARK: - Sub-view helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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

    private func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
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

// ScopeDetailView.swift
// RunnerBar
// #inline-sheets: showHookSheet and showBranchSheet .sheet modifiers replaced
// with ScopeDetailSubScreen enum + ZStack/.move transitions. No child windows.
import RunnerBarCore
import SwiftUI

// MARK: - ScopeDetailSubScreen

/// Navigation state for ScopeEditSheet inline sub-screens.
/// Replaces the old showHookSheet / showBranchSheet @State booleans that
/// each created a child NSSheetWindow and broke the panel chrome.
private enum ScopeDetailSubScreen: Equatable {
    /// The main scope-edit form.
    case main
    /// FailureHookCommandSheet pushed inline.
    case hookCommand
    /// BranchSelectorSheet pushed inline.
    case branchSelector
}

// MARK: - ScopeEditSheet

// Navigation level: SettingsView (scope row tap) → ScopeEditSheet (inline push)
//
// #499: Nav shell + wiring
// #513: Simplified — alias, polling, notifications sections removed.
//       Enable toggle moved from header into its own Monitoring section.
//       Monitoring row removed from Scope Info card.
// #539: Layout improvements -- section labels, card structure aligned with spec.
// #544: Failure Hook section added between Monitoring and Danger Zone.
// #546: Local Path row — inline editing, NSOpenPanel folder picker, tilde pre-fill.
// #559: Failure Hook section hidden for org scopes — only shown for repo scopes.
// #560: Branch selector row added to Failure Hook section.
// #973: Remove Danger Zone and monitoring toggle — Settings is single source of truth.
// #992: Converted from nav drill-down to modal sheet with explicit Cancel / Save.
//       All edits are staged locally; ScopePreferencesStore is only written on Save.
//       NSOpenPanel runs without closing the panel — the NSPanel is non-activating
//       so it does not obscure the picker.
// #inline-sheets: .sheet modifiers for HookCommand and BranchSelector replaced
//       with inline ZStack push. See ScopeDetailSubScreen.
/// Modal sheet for editing settings of a single scope (org or repo).
/// Presented when the user taps a scope row in `SettingsView`.
struct ScopeEditSheet: View {
    /// The scope entry being inspected. Treated as a snapshot; live state is
    /// re-read from `ScopeStore` via `liveEntry`.
    let scopeEntry: ScopeEntry
    /// Controls dismissal. Set to `false` to close without saving;
    /// `confirmSave()` sets it to `false` after persisting changes.
    @Binding var isPresented: Bool

    /// The scopeStore property.
    @ObservedObject private var scopeStore = ScopeStore.shared
    /// Active sub-screen — replaces showHookSheet + showBranchSheet.
    @State private var subScreen: ScopeDetailSubScreen = .main
    /// Slide direction: true = forward (push), false = back (pop).
    @State private var navForward = true
    /// Draft: whether the failure hook is enabled. Written to store only on Save.
    @State private var hookEnabled: Bool
    /// Draft: selected branch filter. Written to store only on Save.
    @State private var hookBranch: String?
    /// Draft: local repo path. Written to store only on Save.
    @State private var localRepoPath: String
    /// The isEditingPath property.
    @State private var isEditingPath = false

    /// Creates the view, seeding `@State` values from `ScopePreferencesStore`.
    init(scopeEntry: ScopeEntry, isPresented: Binding<Bool>) {
        self.scopeEntry = scopeEntry
        self._isPresented = isPresented
        _hookEnabled = State(initialValue: ScopePreferencesStore.failureHookEnabled(for: scopeEntry.scope))
        _hookBranch = State(initialValue: ScopePreferencesStore.failureHookBranch(for: scopeEntry.scope))
        _localRepoPath = State(initialValue: ScopePreferencesStore.localRepoPath(for: scopeEntry.scope) ?? "")
    }

    /// The up-to-date entry from `ScopeStore`.
    private var liveEntry: ScopeEntry? {
        scopeStore.entries.first(where: { $0.id == scopeEntry.id })
    }
    /// Whether monitoring is currently enabled for this scope.
    private var isEnabled: Bool { liveEntry?.isEnabled ?? scopeEntry.isEnabled }
    /// The raw scope string.
    private var scope: String { scopeEntry.scope }
    /// `true` when the scope string contains a slash (repository scope).
    private var isRepo: Bool { scope.contains("/") }
    /// The persisted failure-hook terminal command.
    private var hookCommand: String? { ScopePreferencesStore.failureHookCommand(for: scope) }
    /// The GitHub web URL for this scope.
    private var gitHURL: URL? { URL(string: "https://github.com/\(scope)") }

    /// The body property.
    var body: some View {
        ZStack {
            switch subScreen {
            case .main:
                mainEditForm
                    .transition(.move(edge: navForward ? .leading : .trailing))
            case .hookCommand:
                FailureHookCommandSheet(
                    scope: scope,
                    onDismiss: {
                        navForward = false
                        subScreen = .main
                    }
                )
                .transition(.move(edge: navForward ? .trailing : .leading))
            case .branchSelector:
                BranchSelectorSheet(
                    scope: scope,
                    onDismiss: {
                        navForward = false
                        subScreen = .main
                    },
                    onSelect: { chosen in
                        hookBranch = chosen
                        navForward = false
                        subScreen = .main
                    }
                )
                .transition(.move(edge: navForward ? .trailing : .leading))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: subScreen)
        .frame(width: 440)
        .accessibilityIdentifier("scopeEditSheet")
    }
}

// MARK: - Main form
/// Extension adding functionality to `ScopeEditSheet`.
extension ScopeEditSheet {
    /// The main edit form (header + scroll + footer).
    var mainEditForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    infoSection
                    monitoringSection
                    if isRepo { failureHookSection }
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
            Divider()
            buttonFooter
        }
    }
}

// MARK: - Header & Footer
/// Extension adding functionality to `ScopeEditSheet`.
extension ScopeEditSheet {
    /// Sheet-style title header.
    var sheetHeader: some View {
        HStack(spacing: 6) {
            Text("Edit Scope")
                .font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Text(isRepo ? "Repo" : "Org")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.rbSurfaceElevated))
                    .overlay(Capsule().strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                Text(ScopePreferencesStore.displayName(for: scope))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, RBSpacing.md)
        .padding(.bottom, RBSpacing.sm)
    }

    /// Cancel / Save button row.
    var buttonFooter: some View {
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.escape, modifiers: [])
            Button(action: confirmSave) {
                Text("Save")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.sm)
    }
}

// MARK: - Sections
/// Extension adding functionality to `ScopeEditSheet`.
extension ScopeEditSheet {
    /// Read-only scope metadata card.
    var infoSection: some View {
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

    /// Monitoring status card.
    var monitoringSection: some View {
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
                    Text(isEnabled ? "Active" : "Paused")
                        .font(.caption2)
                        .foregroundColor(isEnabled ? Color.rbSuccess : Color.rbTextTertiary)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
            }
        }
    }

    /// Failure hook configuration card (repo scopes only).
    var failureHookSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Failure Hook")
            infoCard {
                hookToggleRow
                Divider().padding(.leading, RBSpacing.md)
                branchRow
                Divider().padding(.leading, RBSpacing.md)
                localPathRow
                Divider().padding(.leading, RBSpacing.md)
                commandRow
            }
        }
    }
}

// MARK: - Failure Hook Rows
/// Extension adding functionality to `ScopeEditSheet`.
extension ScopeEditSheet {
    /// Toggle row enabling or disabling the failure-hook.
    var hookToggleRow: some View {
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
            Toggle("", isOn: $hookEnabled)
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .labelsHidden()
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
    }

    /// Branch filter row — pushes BranchSelectorSheet inline.
    var branchRow: some View {
        // swiftlint:disable:next multiple_closures_with_trailing_closure
        Button(action: {
            navForward = true
            subScreen = .branchSelector
        }) {
            HStack(spacing: 8) {
                Text("Branch")
                    .font(.system(size: 12))
                    .foregroundColor(Color.rbTextSecondary)
                    .frame(width: 100, alignment: .leading)
                    .fixedSize()
                if let branch = hookBranch {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.rbTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: clearBranchFilter) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color.rbTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear branch filter")
                } else {
                    Text("All branches")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color.rbTextTertiary)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Local repo path row.
    var localPathRow: some View {
        HStack(spacing: 8) {
            Text("Local Path")
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize()
            if isEditingPath {
                TextField("~/code/org/repo", text: $localRepoPath)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.plain)
                    .foregroundColor(Color.rbTextPrimary)
                    .frame(maxWidth: .infinity)
                    .onSubmit { commitLocalPath() }
                Button("Done") { commitLocalPath() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.rbAccent)
            } else {
                // swiftlint:disable:next multiple_closures_with_trailing_closure
                Button(action: { startEditingPath() }) {
                    Text(localRepoPath.isEmpty ? "Tap to set path…" : localRepoPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(localRepoPath.isEmpty ? Color.rbTextTertiary : Color.rbTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Button(action: { openFolderPicker() }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Browse for folder…")
                if !localRepoPath.isEmpty {
                    Button(action: { localRepoPath = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color.rbTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear local path")
                }
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 9)
    }

    /// Command row — pushes FailureHookCommandSheet inline.
    var commandRow: some View {
        // swiftlint:disable:next multiple_closures_with_trailing_closure
        Button(action: {
            navForward = true
            subScreen = .hookCommand
        }) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Actions
/// Extension adding functionality to `ScopeEditSheet`.
extension ScopeEditSheet {
    /// Enters inline editing mode for the local-path field.
    func startEditingPath() {
        if localRepoPath.isEmpty { localRepoPath = "~/" }
        isEditingPath = true
    }

    /// Normalises the draft local path.
    func commitLocalPath() {
        isEditingPath = false
        let trimmed = localRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        localRepoPath = (trimmed == "~/") ? "" : trimmed
    }

    /// Clears the draft branch filter.
    func clearBranchFilter() {
        hookBranch = nil
    }

    /// Writes all draft fields to `ScopePreferencesStore` and dismisses.
    @MainActor func confirmSave() {
        ScopePreferencesStore.setFailureHookEnabled(hookEnabled, for: scope)
        ScopePreferencesStore.setFailureHookBranch(hookBranch, for: scope)
        let path = localRepoPath.isEmpty ? nil : localRepoPath
        ScopePreferencesStore.setLocalRepoPath(path, for: scope)
        isPresented = false
    }

    /// Opens an `NSOpenPanel` to let the user pick the local repository folder.
    func openFolderPicker() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "Select"
        picker.message = "Choose the local folder for \(scope)"
        if !localRepoPath.isEmpty {
            let expanded = NSString(string: localRepoPath).expandingTildeInPath
            picker.directoryURL = URL(fileURLWithPath: expanded)
        } else {
            picker.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { response in
            if response == .OK, let url = picker.url {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let abs = url.path
                let tilde = abs.hasPrefix(home) ? "~/" + abs.dropFirst(home.count + 1) : abs
                localRepoPath = tilde
            }
        }
    }
}

// MARK: - Sub-view helpers
/// Extension adding functionality to `ScopeEditSheet`.
extension ScopeEditSheet {
    /// Renders a styled section-header label.
    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

    /// Wraps `content` in the standard rounded-card background.
    func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .glassCard(cornerRadius: RBRadius.small)
        .padding(.horizontal, RBSpacing.md)
        .padding(.bottom, 8)
    }

    /// Renders a label–value row inside an info card.
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

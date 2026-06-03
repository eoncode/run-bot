// AddRunnerSheet.swift
// RunnerBar
import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - AddRunnerSheet

// MARK: - URI Constants
/// Enumerates possible values for GitHubURIs.
private enum GitHubURIs {
    /// The base constant.
    static let base            = "https://github.com/"
    /// The apiRunnerLatest constant.
    static let apiRunnerLatest = "https://api.github.com/repos/actions/runner/releases/latest"
    /// The launchAgentsDir constant.
    static let launchAgentsDir = "Library/LaunchAgents"
    /// The actionsRunnerDefaultDir constant.
    static let actionsRunnerDefaultDir = "actions-runner/my-runner"
}

/// Sheet view for onboarding a self-hosted runner.
///
/// Supports two modes selectable via a segmented control at the top:
///
/// - **Add new**: downloads, configures and registers a brand-new runner with GitHub.
/// - **Add pre-existing**: imports a runner folder that was already configured outside
///   of RunnerBar (e.g. via terminal). Only writes the LaunchAgent plist so
///   the runner can be managed — no token or download needed.
///
/// After successful registration/import the app writes a minimal LaunchAgent plist to
/// `~/Library/LaunchAgents/actions.runner.<owner>.<repo>.<name>.plist` directly
/// via FileManager, and registers the runner in `LocalRunnerStore`.
///
/// Requires a GitHub token for "Add new" (OAuth sign-in, GH_TOKEN, or GITHUB_TOKEN).
struct AddRunnerSheet: View {
    /// Controls whether the sheet is shown.
    @Binding var isPresented: Bool
    /// Called when registration or import completes successfully.
    let onComplete: () -> Void

    // MARK: - Add Mode

    /// Controls which form body is shown in the sheet.
    enum AddMode: String, CaseIterable, Identifiable {
        /// Onboards a fresh runner via download + registration token.
        case addNew      = "Add new"
        /// Imports a runner folder that was configured outside of RunnerBar.
        case addExisting = "Add pre-existing"
        /// Stable identity backed by `rawValue`.
        var id: String { rawValue }
    }

    /// Whether the user is adding a new runner or importing a pre-existing one.
    @State private var addMode: AddMode = .addNew

    // MARK: Scope state (Add new only)

    /// Determines whether the runner is registered at repo or organisation scope.
    enum ScopeType: String, CaseIterable, Identifiable {
        /// Runner registered to a single repository.
        case repo = "Repository"
        /// Runner registered at organisation level.
        case org  = "Organisation"
        /// Stable identity backed by `rawValue`.
        var id: String { rawValue }
    }

    /// Whether the runner is repo-scoped or org-scoped.
    @State private var scopeType: ScopeType = .repo
    /// Selected repository slug (used when `scopeType == .repo`).
    @State private var selectedRepo = ""
    /// Selected organisation name (used when `scopeType == .org`).
    @State private var selectedOrg  = ""
    /// Repository slugs fetched from GitHub for the picker.
    @State private var repos: [String] = []
    /// Organisation names fetched from GitHub for the picker.
    @State private var orgs:  [String] = []
    /// `true` while scope options are being fetched from GitHub.
    @State private var isLoadingScopes = false
    /// `true` while the repository-selector sheet is presented.
    @State private var showRepoSelector = false
    /// `true` while the organisation-selector sheet is presented.
    @State private var showOrgSelector  = false

    // MARK: Runner config state (Add new only)

    /// Display name the runner will register with.
    @State private var runnerName = ""
    /// Comma-separated label string pre-populated with defaults.
    @State private var labelsText = "self-hosted,macOS"
    /// Default: ~/actions-runner/my-runner — user should rename the last
    /// component to match their runner name. Each runner needs its own folder.
    @State private var installDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(GitHubURIs.actionsRunnerDefaultDir).path

    // MARK: Registration state (Add new only)

    /// `true` while the registration command is running.
    @State private var isRegistering    = false
    /// Human-readable description of the current registration step.
    @State private var registrationStep = ""
    /// Non-nil when registration fails; shown as an inline error.
    @State private var errorMessage: String?

    // MARK: Pre-existing state (Add pre-existing only)

    /// The folder path the user selected via NSOpenPanel.
    @State private var existingDir = ""
    /// Runner name parsed from the `.runner` JSON inside `existingDir`.
    @State private var detectedName = ""
    /// GitHub URL parsed from the `.runner` JSON inside `existingDir`.
    @State private var detectedGitHubURL = ""
    /// Shown when the selected folder has no valid `.runner` file or it can't be parsed.
    @State private var existingError: String?
    /// Editable fallback shown when `.runner` JSON has no `gitHubUrl` (rare, org-scoped runners).
    @State private var githubURLOverride = ""
    /// Whether a runner with this name is already in LocalRunnerStore's index.
    @State private var isDuplicate = false

    // MARK: - Body

    /// Root layout: mode picker, form body, and action bar.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add runner").font(.headline)

            // MARK: Mode toggle
            Picker("Mode", selection: $addMode) {
                ForEach(AddMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: addMode) { _, _ in
                resetAddNewState()
                resetExistingState()
            }

            Divider()

            // MARK: Form body branch
            if addMode == .addNew {
                addNewFormBody
            } else {
                addExistingFormBody
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if addMode == .addNew { loadScopes() }
        }
    }

    // MARK: - Add New Form Body

    /// Form fields shown when the user selects the "Add new" mode:
    /// scope picker, repo/org selector, token field, runner name, and install path.
    @ViewBuilder
    private var addNewFormBody: some View {
        Picker("Scope", selection: $scopeType) {
            ForEach(ScopeType.allCases) { s in Text(s.rawValue).tag(s) }
        }
        .pickerStyle(.segmented)

        if isLoadingScopes {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text("Loading\u{2026}").font(.caption).foregroundColor(.secondary)
            }
        } else if scopeType == .repo {
            selectorButton(
                label: "Repository",
                selection: selectedRepo,
                action: { showRepoSelector = true }
            )
            .sheet(isPresented: $showRepoSelector) {
                RepoSelectorSheet(
                    items: repos,
                    label: "Repository",
                    onDismiss: { showRepoSelector = false },
                    onSelect: { item in
                        // No dismiss here -- RepoSelectorSheet.itemRow calls onDismiss after onSelect.
                        selectedRepo = item
                    }
                )
            }
        } else {
            selectorButton(
                label: "Organisation",
                selection: selectedOrg,
                action: { showOrgSelector = true }
            )
            .sheet(isPresented: $showOrgSelector) {
                RepoSelectorSheet(
                    items: orgs,
                    label: "Organisation",
                    onDismiss: { showOrgSelector = false },
                    onSelect: { item in
                        // No dismiss here -- RepoSelectorSheet.itemRow calls onDismiss after onSelect.
                        selectedOrg = item
                    }
                )
            }
        }

        labeledField("Runner name", placeholder: "e.g. my-mac-runner", text: $runnerName)
        labeledField(
            "Labels (comma-separated)",
            placeholder: "e.g. self-hosted,macOS,arm64",
            text: $labelsText
        )

        VStack(alignment: .leading, spacing: 4) {
            Text("Runner install directory").font(.caption).foregroundColor(.secondary)
            TextField("", text: $installDir)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Text(
                "Each runner needs its own unique folder. Use the runner name as the last path component, e.g. ~/actions-runner/my-runner."
            )
            .font(.caption2)
            .foregroundColor(.secondary)
            if dirAlreadyConfigured {
                Label(
                    "This folder already has a runner configured. Choose a different path.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundColor(.orange)
            }
        }

        if isRegistering && !registrationStep.isEmpty {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text(registrationStep).font(.caption).foregroundColor(.secondary)
            }
        }

        if let err = errorMessage {
            Text(err)
                .font(.caption).foregroundColor(.red)
                .padding(8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
        }

        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .disabled(isRegistering)
            Button {
                Task { await register() }
            } label: {
                if isRegistering {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                        Text("Registering\u{2026}")
                    }
                } else {
                    Text("Add new runner")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRegister || isRegistering)
        }
    }

    // MARK: - Add Pre-Existing Form Body

    /// Form fields shown when the user selects the "Add pre-existing" mode:
    /// folder picker, detected runner name, and GitHub URL display/override.
    @ViewBuilder
    private var addExistingFormBody: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Folder picker row
            VStack(alignment: .leading, spacing: 4) {
                Text("Runner install folder").font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text(existingDir.isEmpty ? "No folder selected" : existingDir)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(existingDir.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        pickExistingFolder()
                    } label: {
                        Text("Choose\u{2026}")
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)

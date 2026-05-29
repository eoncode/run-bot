// AddScopeSheet.swift
// RunnerBar
// #inline-sheets: .sheet(isPresented: $showScopeSelector) replaced with inline
// push using AddScopeSubScreen enum. No child NSWindow is ever created.
import SwiftUI

// MARK: - ScopeType

/// Enumerates possible values for ScopeType.
private enum ScopeType: String, CaseIterable, Identifiable {
    /// Coding key for the `org` field.
    case org  = "Organisation"
    /// Coding key for the `repo` field.
    case repo = "Repository"
    /// The id property.
    var id: String { rawValue }
}

// MARK: - AddScopeSubScreen

/// Navigation state for AddScopeSheet inline sub-screens.
private enum AddScopeSubScreen: Equatable {
    /// The main add-scope form.
    case main
    /// The repo/org selector list pushed inline.
    case repoSelector
}

// MARK: - AddScopeSheet

/// Inline view for adding a new remote runner scope (org or repo).
/// Embedded inside SettingsView's ZStack — not presented as a .sheet.
struct AddScopeSheet: View {
    /// The isPresented property.
    @Binding var isPresented: Bool

    /// The scopeType property.
    @State private var scopeType: ScopeType = .org
    /// The selectedScope property.
    @State private var selectedScope: String = ""
    /// The manualScope property.
    @State private var manualScope: String = ""
    /// The orgs property.
    @State private var orgs: [String] = []
    /// The repos property.
    @State private var repos: [String] = []
    /// The isFetching property.
    @State private var isFetching = false
    /// The errorMessage property.
    @State private var errorMessage: String?
    /// The usePicker property.
    @State private var usePicker = false
    /// Sub-screen nav state — replaces showScopeSelector .sheet.
    @State private var subScreen: AddScopeSubScreen = .main
    /// Slide direction: true = forward (push), false = back (pop).
    @State private var navForward = true

    /// The list of picker options matching the current `scopeType` (orgs or repos).
    private var pickerItems: [String] {
        scopeType == .org ? orgs : repos
    }

    /// The scope string that will be saved.
    private var effectiveScope: String {
        usePicker ? selectedScope : manualScope.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Guards the Add button.
    private var canAdd: Bool { !effectiveScope.isEmpty }

    /// The body property.
    var body: some View {
        ZStack {
            switch subScreen {
            case .main:
                mainForm
                    .transition(.move(edge: navForward ? .leading : .trailing))
            case .repoSelector:
                RepoSelectorSheet(
                    items: pickerItems,
                    label: scopeType == .org ? "Organisation" : "Repository",
                    onDismiss: {
                        navForward = false
                        subScreen = .main
                    },
                    onSelect: { item in
                        selectedScope = item
                        navForward = false
                        subScreen = .main
                    }
                )
                .transition(.move(edge: navForward ? .trailing : .leading))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: subScreen)
        .frame(width: 420)
        .onAppear(perform: fetchScopeOptions)
    }

    // MARK: - Main form

    private var mainForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ─────────────────────────────────────────────────────
            Text("Add remote scope")
                .font(.headline)
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, RBSpacing.md)
                .padding(.bottom, RBSpacing.sm)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: RBSpacing.md) {

                    // ── Type toggle ──────────────────────────────────────────
                    Picker("", selection: $scopeType) {
                        ForEach(ScopeType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: scopeType) { _, _ in
                        selectedScope = pickerItems.first ?? ""
                        subScreen = .main
                    }

                    // ── Scope picker / text field ────────────────────────────
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scopeType == .org ? "Organisation" : "Repository")
                            .font(.caption)
                            .foregroundColor(Color.rbTextSecondary)

                        if isFetching {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text("Fetching from GitHub\u{2026}")
                                    .font(.caption)
                                    .foregroundColor(Color.rbTextSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        } else if usePicker && !pickerItems.isEmpty {
                            // ── Selector trigger — pushes inline ─────────────
                            Button(action: {
                                navForward = true
                                subScreen = .repoSelector
                            }) {
                                HStack {
                                    Text(selectedScope.isEmpty ? "\u{2014} select \u{2014}" : selectedScope)
                                        .font(.system(size: 12))
                                        .foregroundColor(
                                            selectedScope.isEmpty
                                                ? Color.rbTextTertiary
                                                : Color.rbTextPrimary
                                        )
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color.rbTextTertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.rbSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            TextField(
                                scopeType == .org ? "e.g. myorg" : "e.g. myorg/myrepo",
                                text: $manualScope
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        }

                        if let err = errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(Color.rbDanger)
                        }
                    }

                    // ── Helper caption ───────────────────────────────────────
                    Text(scopeType == .org
                         ? "Monitors all runners in the organisation."
                         : "Monitors runners registered to this repository.")
                    .font(.caption)
                    .foregroundColor(Color.rbTextSecondary)
                }
                .padding(RBSpacing.md)
            }

            Divider()

            // ── Button row ─────────────────────────────────────────────────
            HStack {
                Spacer()

                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)

                Button(action: confirmAdd) {
                    Text("Add Scope")
                        .font(.system(size: 13, weight: .medium))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, RBSpacing.sm)
        }
    }

    // MARK: - Actions

    /// Fetches orgs and repos from GitHub on a background thread.
    private func fetchScopeOptions() {
        guard githubToken() != nil else {
            log("AddScopeSheet › no token — falling back to text field")
            usePicker = false
            return
        }
        isFetching = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let fetchedOrgs  = fetchUserOrgs()
            let fetchedRepos = fetchUserRepos()
            DispatchQueue.main.async {
                isFetching = false
                if fetchedOrgs.isEmpty && fetchedRepos.isEmpty {
                    log("AddScopeSheet › fetch returned no orgs or repos — using text field")
                    usePicker = false
                    errorMessage = "Could not load orgs/repos. Enter manually."
                } else {
                    orgs  = fetchedOrgs
                    repos = fetchedRepos
                    usePicker = true
                    selectedScope = pickerItems.first ?? ""
                    log("AddScopeSheet › loaded orgs=\(orgs.count) repos=\(repos.count)")
                }
            }
        }
    }

    /// Persists `effectiveScope` to `ScopeStore` and dismisses.
    @MainActor private func confirmAdd() {
        let scope = effectiveScope
        guard !scope.isEmpty else { return }
        ScopeStore.shared.add(scope)
        RunnerStore.shared.start()
        log("AddScopeSheet › added scope: \(scope)")
        isPresented = false
    }
}

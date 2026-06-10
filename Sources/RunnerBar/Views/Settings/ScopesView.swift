// ScopesView.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - ScopesView

/// Full scope-management screen, reached from the "Manage scopes" row in Settings.
///
/// Owns all scope-specific state and sheet presentation that previously lived in `SettingsView`.
/// Presented by `SettingsView` via a `showScopes` flag using the same back-callback
/// pattern established by the rest of the panel navigation model.
@MainActor
struct ScopesView: View {

    // MARK: - Inputs

    /// Callback invoked when the user taps the back button.
    let onBack: () -> Void
    /// Called whenever a scope change requires the poll loop to restart.
    /// Injected by the caller (AppDelegate / navigation layer) so this view
    /// holds no reference to `RunnerStore` directly.
    var onRestartPolling: () -> Void = {}

    // MARK: - Observed stores

    /// Registered remote runner scopes (org / repo URLs).
    @State private var scopeStore = ScopeStore.shared

    // MARK: - Local UI state

    /// Controls presentation of `AddScopeSheet`.
    @State private var showAddScopeSheet = false
    /// Non-nil while `ScopeEditSheet` is presented for this scope entry.
    @State private var selectedScopeEntry: ScopeEntry?

    // MARK: - Body

    /// Root layout: fixed header bar above a scrollable scope list.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                contentStack
                    .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .sheet(isPresented: $showAddScopeSheet) {
            AddScopeSheet(
                isPresented: $showAddScopeSheet,
                onRestartPolling: onRestartPolling
            )
        }
        .sheet(item: $selectedScopeEntry) { entry in
            // #992: ScopeEditSheet replaces the old nav drill-down.
            ScopeEditSheet(
                scopeEntry: entry,
                isPresented: Binding(
                    get: { selectedScopeEntry != nil },
                    set: { if !$0 { selectedScopeEntry = nil } }
                )
            )
        }
    }

    // MARK: - Header

    /// Top bar with back button and "Manage scopes" title.
    private var headerBar: some View {
        HStack {
            Button(action: onBack, label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Manage scopes").font(.headline)
                }
                .foregroundColor(.primary)
            })
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: - Content

    /// Vertical stack of the section header and scope list.
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            descriptionLabel
            scopeList
        }
    }

 
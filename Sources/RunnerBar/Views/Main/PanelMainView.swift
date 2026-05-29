// PanelMainView.swift
// RunnerBar
import RunnerBarCore
import SwiftUI
// REGRESSION GUARD — DO NOT REMOVE - see regression history (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE: NSPopover + sizingOptions=.preferredContentSize
// Dynamic height is achieved via KVO on NSHostingController.preferredContentSize.
// AppDelegate observes it and calls popover.contentSize (height only) — zero jump.
// SwiftUI views report their natural ideal size. No height caps needed here.
//
// RULE 1: Root VStack uses .frame(minWidth: 280, maxWidth: 900, alignment: .top)
// NOTE: idealWidth: 480 is set to match AppDelegate.popoverWidth exactly.
// This prevents NSPopover from receiving a mismatched preferred width.
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerViewModel.reload() uses withAnimation(nil).
//
// RULE 5: actionsSection is wrapped in a ScrollView capped at screenScrollMaxHeight.
// screenScrollMaxHeight = NSScreen.main.visibleFrame.height * 0.80.
// ❌ NEVER remove the ScrollView from actionsSection.
// ❌ NEVER use a GeometryReader or preference key for this cap.
// ❌ NEVER add .frame(maxHeight:) to the root VStack instead.
// ❌ NEVER replace the ScrollView with ViewThatFits.
//
// RULE 6: systemStats MUST run only while the panel is open.
// RULE 6b: systemStats must START when the panel opens.
//
// RULE 7: RunnerStore self-schedules via its own adaptive timer.
// ❌ NEVER add a second repeating timer that calls store.reload().
//
// RULE 8: AppDelegate.popoverWidth is 480.
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
//
// BACKGROUND (#1017):
// NSPopover provides its own glass chrome. No .background() modifier needed here.
// ❌ NEVER add NSVisualEffectView or .background(.regularMaterial) at this level —
// it fights the native popover chrome and produces a double-layer artefact.
/// Root panel view rendered inside the NSPopover.
/// Owns the display-tick timer and system-stats lifecycle.
/// API polling is owned entirely by RunnerStore's adaptive self-scheduling timer.
struct PanelMainView: View {
    /// The store property.
    @ObservedObject var store: RunnerViewModel
    /// Called when user taps a step row in an inline job list. (#455)
    let onStepTap: (ActiveJob, JobStep) -> Void
    /// The onSelectSettings constant.
    let onSelectSettings: () -> Void
    /// The panelVisibilityState property.
    @EnvironmentObject private var panelVisibilityState: PanelVisibilityState
    /// The isAuthenticated property.
    @State private var isAuthenticated = (githubToken() != nil)
    /// The systemStats property.
    @StateObject private var systemStats = SystemStatsViewModel()
    /// The visibleCount property.
    @State private var visibleCount: Int = 10
    /// The displayTick property.
    @State private var displayTick: Int = 0
    /// The displayTickTimer property.
    @State private var displayTickTimer: Timer?
    /// Maximum height for the scrollable actions section.
    private var screenScrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    /// The subset of locally-installed runners that are currently active.
    private var activeLocalRunners: [RunnerModel] {
        guard store.actions.contains(where: { $0.groupStatus == .inProgress }) else { return [] }
        let activeNamesFromJobs = Set(
            store.jobs
                .filter { $0.status == .inProgress }
                .compactMap { $0.runnerName }
        )
        let busyRunners = store.runners.filter { $0.busy }
        let busyIds = Set(busyRunners.compactMap { $0.id })
        let busyNames = Set(busyRunners.map { $0.name })
        return store.localRunners.filter { local in
            if activeNamesFromJobs.contains(local.runnerName) { return true }
            if let aid = local.agentId, busyIds.contains(aid) { return true }
            if busyNames.contains(local.runnerName) { return true }
            return false
        }
    }

    /// Root body.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeaderView(
                statsVM: systemStats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: signInWithGitHub
            )
            .onAppear { systemStats.start() }
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
            if !activeLocalRunners.isEmpty {
                SectionHeaderLabel(title: "Local Runners")
                PanelLocalRunnerRow(runners: activeLocalRunners)
            }
            Color.clear.frame(width: 0, height: 0)
                .onAppear {
                    Task { await MainActor.run { LocalRunnerStore.shared.refresh() } }
                }
            actionsSectionScrollable
        }
        // idealWidth matches AppDelegate.popoverWidth so NSHostingController
        // reports the correct preferred width and popover anchoring is stable.
        // ❌ NEVER change idealWidth without updating AppDelegate.popoverWidth.
        .frame(minWidth: 280, idealWidth: 480, maxWidth: 900, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            if panelVisibilityState.isOpen { systemStats.start() }
            startDisplayTickTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopDisplayTickTimer()
        }
        .onChange(of: panelVisibilityState.isOpen) { _, open in
            if open { systemStats.start() } else { systemStats.stop() }
        }
        .onChange(of: store.actions) { _, _ in visibleCount = 10 }
    }

    // MARK: - Scrollable actions section (RULE 5)
    private var actionsSectionScrollable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            actionsSectionContent
        }
        .frame(maxHeight: screenScrollMaxHeight)
    }

    private var actionsSectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(title: "Workflows")
            if store.actions.isEmpty {
                Text("No recent workflows")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                let visible = Array(store.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    ActionRowView(
                        group: group,
                        tick: displayTick,
                        onStepTap: onStepTap
                    )
                }
                loadMoreButton
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var loadMoreButton: some View {
        let nextBatch = min(10, store.actions.count - visibleCount)
        if nextBatch > 0 {
            Button(
                action: { visibleCount += nextBatch },
                label: {
                    Text("Load \(nextBatch) more workflows\u{2026}")
                        .font(.caption).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: - Display tick timer (RULE 9)
    private func startDisplayTickTimer() {
        stopDisplayTickTimer()
        displayTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in self.displayTick &+= 1 }
        }
    }

    private func stopDisplayTickTimer() {
        displayTickTimer?.invalidate()
        displayTickTimer = nil
    }

    // MARK: - Rate limit banner
    private var rateLimitBanner: some View {
        _ = displayTick // swiftlint:disable:this redundant_discardable_let
        let countdownLabel: String
        if let resetDate = store.rateLimitResetDate {
            let remaining = max(0, resetDate.timeIntervalSinceNow)
            if remaining < 1 {
                countdownLabel = "resuming\u{2026}"
            } else if remaining < 60 {
                countdownLabel = "resets in \(Int(remaining))s"
            } else {
                let mins = Int(remaining) / 60
                let secs = Int(remaining) % 60
                countdownLabel = String(format: "resets in %dm %02ds", mins, secs)
            }
        } else {
            countdownLabel = "pausing polls"
        }
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow).font(.caption)
            Text("GitHub rate limit reached — \(countdownLabel)")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: - Helpers
    private func signInWithGitHub() {
        let urlString = "\(GitHubConstants.base)/en/authentication/"
            + "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

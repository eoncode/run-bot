// PanelMainView.swift
// RunnerBar
import RunnerBarCore
import SwiftUI
// REGRESSION GUARD — DO NOT REMOVE - see regression history (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE: NSPanel + sizingOptions=.preferredContentSize
// Dynamic height is achieved via KVO on NSHostingController.preferredContentSize.
// AppDelegate observes it and calls NSPanel.setFrame() — zero jump (no anchor).
// SwiftUI views report their natural ideal size. No height caps needed here.
//
// RULE 1: Root VStack uses .frame(minWidth: 280, maxWidth: 900, alignment: .top)
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerViewModel.reload() uses withAnimation(nil).
//
// RULE 5: actionsSection is wrapped in a ScrollView capped at screenScrollMaxHeight.
// screenScrollMaxHeight = NSScreen.main.visibleFrame.height * 0.80.
// This mirrors AppDelegate's 85% panel ceiling minus headroom for the header
// and runner rows above the list. The ScrollView is transparent for short lists
// (content fits, no scroll indicator) and activates only when expanded rows
// would push content off screen.
// ❌ NEVER remove the ScrollView from actionsSection.
// ❌ NEVER use a GeometryReader or preference key for this cap — it freezes
// at the initial layout height and prevents scrolling to expanded content.
// ❌ NEVER add .frame(maxHeight:) to the root VStack instead.
//
// RULE 6: systemStats MUST run only while the panel is open — stop it when the panel closes.
// RULE 6b: systemStats must START when the panel opens so charts are live while the user views them.
//
// RULE 7: RunnerStore self-schedules via its own adaptive timer after each fetch().
// ❌ NEVER add a second repeating timer in PanelMainView that calls
// store.reload() — it doubles API calls and drains GitHub quota.
// LocalRunnerStore.refresh() (local-only, no API) may be called from onAppear.
//
// RULE 8: AppDelegate.initPanelWidth is 320.
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
/// Root panel view rendered inside the NSPanel.
/// Owns the display-tick timer and system-stats lifecycle.
/// API polling is owned entirely by RunnerStore's adaptive self-scheduling timer.
struct PanelMainView: View {
    // swiftlint:disable missing_docs
    @ObservedObject var store: RunnerViewModel
    let onStepTap: (ActiveJob, JobStep) -> Void
    let onSelectSettings: () -> Void
    @EnvironmentObject private var panelVisibilityState: PanelVisibilityState
    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var displayTick: Int = 0
    @State private var displayTickTimer: Timer?
    // swiftlint:enable missing_docs
    private var screenScrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }
    private var hasBusyLocalRunners: Bool {
        store.localRunners.contains { $0.isBusy }
            && store.actions.contains { $0.groupStatus == .inProgress }
    }
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
            if hasBusyLocalRunners {
                SectionHeaderLabel(title: "Local Runners")
                PanelLocalRunnerRow(runners: store.localRunners)
            }
            Color.clear.frame(width: 0, height: 0)
                .onAppear {
                    Task { await MainActor.run { LocalRunnerStore.shared.refresh() } }
                }
            actionsSectionScrollable
        }
        .frame(minWidth: 280, maxWidth: 900, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            if panelVisibilityState.isOpen { systemStats.start() }
            startDisplayTickTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopDisplayTickTimer()
        }
        .onChange(of: panelVisibilityState.isOpen) { open in
            if open { systemStats.start() } else { systemStats.stop() }
        }
        .onChange(of: store.actions) { _ in visibleCount = 10 }
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
                    Text("Load \(nextBatch) more workflows…")
                        .font(.caption).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
    // MARK: - Display tick timer (RULE 9 — ungated, 1s)
    private func startDisplayTickTimer() {
        stopDisplayTickTimer()
        displayTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.displayTick &+= 1
        }
    }
    private func stopDisplayTickTimer() {
        displayTickTimer?.invalidate()
        displayTickTimer = nil
    }
    // MARK: - Rate limit banner (#778)
    private var rateLimitBanner: some View {
        // Capture tick to force a re-evaluation every second.
        _ = displayTick // swiftlint:disable:this redundant_discardable_let
        let countdownLabel: String
        if let resetDate = store.rateLimitResetDate {
            let remaining = max(0, resetDate.timeIntervalSinceNow)
            if remaining < 1 {
                countdownLabel = "resuming…"
            } else if remaining < 60 {
                countdownLabel = "resets in \(Int(remaining))s"
            } else {
                let m = Int(remaining) / 60
                let s = Int(remaining) % 60
                countdownLabel = String(format: "resets in %dm %02ds", m, s)
            }
        } else {
            countdownLabel = "pausing polls"
        }
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text("Rate limited — \(countdownLabel)")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }
}

import AppKit
import SwiftUI

// MARK: - RowContextMenus
// Context menus for main-view row items (workflow rows and job rows).
// Both modifiers are thin View-extension wrappers so the call sites stay one-liners.
//
// Call sites:
//   ActionRowView (PopoverMainViewSubviews.swift)  → .workflowContextMenu(group:)
//   JobRowCard    (InlineJobRowsView.swift)         → .jobContextMenu(job:group:)
//
// Issue: #454

// MARK: - Workflow context menu

extension View {
    /// Attaches a workflow-level right-click context menu to any view.
    /// Actions mirror those in ActionDetailView's header bar.
    func workflowContextMenu(group: ActionGroup) -> some View {
        modifier(WorkflowContextMenuModifier(group: group))
    }
}

private struct WorkflowContextMenuModifier: ViewModifier {
    let group: ActionGroup

    private var isConcluded: Bool { group.groupStatus == .completed }
    private var isLive: Bool      { group.groupStatus == .inProgress }

    func body(content: Content) -> some View {
        content.contextMenu {
            // ── Re-run failed (concluded only) ────────────────────────────────
            Button {
                let scope  = group.repo
                let runIDs = group.runs.map { $0.id }
                DispatchQueue.global(qos: .userInitiated).async {
                    runIDs.forEach { ghPost("repos/\(scope)/actions/runs/\($0)/rerun-failed-jobs") }
                }
            } label: {
                Label("Re-run Failed", systemImage: "arrow.clockwise")
            }
            .disabled(!isConcluded)

            // ── Re-run all (concluded only) ───────────────────────────────────
            Button {
                let scope  = group.repo
                let runIDs = group.runs.map { $0.id }
                DispatchQueue.global(qos: .userInitiated).async {
                    runIDs.forEach { ghPost("repos/\(scope)/actions/runs/\($0)/rerun") }
                }
            } label: {
                Label("Re-run All", systemImage: "arrow.clockwise.circle")
            }
            .disabled(!isConcluded)

            // ── Cancel (live only) ────────────────────────────────────────────
            Button(role: .destructive) {
                let scope  = group.repo
                let runIDs = group.runs.map { $0.id }
                DispatchQueue.global(qos: .userInitiated).async {
                    runIDs.forEach { cancelRun(runID: $0, scope: scope) }
                }
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .disabled(!isLive)

            Divider()

            // ── Copy log (all jobs and steps in this workflow) ─────────────────
            Button {
                let g = group
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let text = fetchActionLogs(group: g), !text.isEmpty else { return }
                    DispatchQueue.main.async {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            } label: {
                Label("Copy Log", systemImage: "doc.on.doc")
            }

            Divider()

            // ── Show workflow file ────────────────────────────────────────────
            Button {
                guard let run = group.runs.first else { return }
                let safeName = run.name
                    .lowercased()
                    .components(separatedBy: .whitespaces).joined(separator: "-")
                let urlStr = "https://github.com/\(group.repo)/blob/\(group.headSha)/.github/workflows/\(safeName).yml"
                if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
            } label: {
                Label("Show Workflow File", systemImage: "doc.text")
            }

            // ── Show GitHub SHA ───────────────────────────────────────────────
            Button {
                let urlStr = "https://github.com/\(group.repo)/commit/\(group.headSha)"
                if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
            } label: {
                Label("Show GitHub SHA", systemImage: "number.square")
            }
        }
    }
}

// MARK: - Job context menu

extension View {
    /// Attaches a job-level right-click context menu to any view.
    /// Actions mirror those in JobDetailView's header bar.
    func jobContextMenu(job: ActiveJob, group: ActionGroup) -> some View {
        modifier(JobContextMenuModifier(job: job, group: group))
    }
}

private struct JobContextMenuModifier: ViewModifier {
    let job: ActiveJob
    let group: ActionGroup

    private var isConcluded: Bool { job.conclusion != nil }
    private var isLive: Bool      { job.status == "in_progress" }

    func body(content: Content) -> some View {
        content.contextMenu {
            // ── Re-run (concluded only) ───────────────────────────────────────
            Button {
                let scope = group.repo
                guard let runID = group.runs.first?.id else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    ghPost("repos/\(scope)/actions/runs/\(runID)/rerun")
                }
            } label: {
                Label("Re-run", systemImage: "arrow.clockwise")
            }
            .disabled(!isConcluded)

            // ── Cancel (live only) ────────────────────────────────────────────
            Button(role: .destructive) {
                let scope = group.repo
                guard let runID = group.runs.first?.id else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    cancelRun(runID: runID, scope: scope)
                }
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .disabled(!isLive)

            Divider()

            // ── Copy log (all steps in this job) ──────────────────────────────
            Button {
                let jobID = job.id
                let scope = group.repo
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let text = fetchJobLog(jobID: jobID, scope: scope), !text.isEmpty else { return }
                    DispatchQueue.main.async {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            } label: {
                Label("Copy Log", systemImage: "doc.on.doc")
            }

            Divider()

            // ── Show on GitHub ────────────────────────────────────────────────
            Button {
                guard let urlStr = job.htmlUrl, let url = URL(string: urlStr) else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Label("Show on GitHub", systemImage: "safari")
            }
            .disabled(job.htmlUrl == nil)
        }
    }
}

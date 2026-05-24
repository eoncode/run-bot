// InlineJobRowsView.swift
// RunnerBar
// swiftlint:disable redundant_discardable_let
import RunnerBarCore
import SwiftUI
// MARK: - TreeLineLeader
/// Vertical tree-connector line drawn to the left of a job or step row.
/// Renders a straight bar with an elbow arrow at the bottom for the last item.
private struct TreeLineLeader: View {
    /// True when this is the last sibling in the list; shortens the vertical bar to the row midpoint.
    let isLast: Bool
    /// Horizontal offset (in points) from the view’s left edge to the vertical bar centre.
    var indent: CGFloat = 0
    /// Colour used for all tree-line strokes and arrow fill.
    private let lineColor = Color.secondary.opacity(0.3)
    /// Stroke width of the vertical bar and elbow line in points.
    private let barWidth: CGFloat = 1
    /// Horizontal length of the elbow arm extending from the vertical bar to the row content.
    private let elbowWidth: CGFloat = 10
    /// Half-height of the arrowhead triangle at the elbow tip, in points.
    private let arrowSize: CGFloat = 4
    /// Draws the vertical bar, horizontal elbow, and arrowhead using Canvas.
    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let barX = indent
            var vertPath = Path()
            vertPath.move(to: CGPoint(x: barX, y: 0))
            vertPath.addLine(to: CGPoint(x: barX, y: isLast ? midY : size.height))
            ctx.stroke(vertPath, with: .color(lineColor), lineWidth: barWidth)
            let arrowTip = CGPoint(x: barX + elbowWidth, y: midY)
            var elbowPath = Path()
            elbowPath.move(to: CGPoint(x: barX, y: midY))
            elbowPath.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY))
            ctx.stroke(elbowPath, with: .color(lineColor), lineWidth: barWidth)
            var arrow = Path()
            arrow.move(to: arrowTip)
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY - arrowSize / 2))
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY + arrowSize / 2))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(lineColor))
        }
        .frame(width: indent + elbowWidth + 2)
    }
}

// MARK: - JobInlineProgress
/// Compact progress bar shown inside a job row while the job is running.
/// Fills proportionally to `fractionComplete`; hidden when no progress is available.
private struct JobInlineProgress: View {
    /// Progress fraction in the range 0.0–1.0 used to scale the filled capsule width.
    let progress: Double
    /// Renders a faint background capsule with a blue filled capsule scaled to `progress`.
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rbTextTertiary.opacity(0.22)).frame(height: 3)
                Capsule()
                    .fill(Color.rbBlue)
                    .frame(width: max(3, geo.size.width * CGFloat(progress)), height: 3)
            }
        }
        .frame(height: 3)
    }
}

// MARK: - StepRowView
/// Single step row inside an expanded job card.
/// Shows the step icon, name, and elapsed time aligned with the tree connector.
private struct StepRowView: View {
    /// The step model to render.
    let step: JobStep
    /// The parent job; passed through to the context menu modifier.
    let job: ActiveJob
    /// True when this step is the last in the job’s step list; affects the tree-line termination.
    let isLast: Bool
    /// Called when the user taps this step row to open the log viewer.
    let onTap: () -> Void
    // indent = 9: centers the vertical bar under the job DonutStatusView dot.
    // Geometry: InlineJobRowsView.padding(.leading:12) + jobLeaderFrame(19) +
    // stepsContainer.padding(.horizontal:4) = 35 from InlineJobRowsView edge.
    // Job dot center = 12 + 19 + 8(card hpad) + 5(half dot10) = 44.
    // Step leader indent = 44 - 35 = 9.
    /// Horizontal offset aligning the step tree-line bar under the job’s DonutStatusView dot centre.
    private let dotIndent: CGFloat = 9
    /// Renders the tree-line leader alongside the tappable step content.
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TreeLineLeader(isLast: isLast, indent: dotIndent)
                .frame(maxHeight: .infinity)
            stepContent
        }
    }
    /// The tappable button containing the step icon, name, elapsed time, and chevron.
    private var stepContent: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(step.conclusionIcon)
                    .font(.system(size: 10))
                    .foregroundColor(iconColor)
                    .fixedSize()
                Text(step.name)
                    .font(DesignTokens.Fonts.mono)
                    .foregroundColor(Color.rbTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if step.status == .inProgress || step.conclusion != nil {
                    Text(step.elapsed)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextTertiary)
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.rbTextTertiary)
            }
            .padding(.horizontal, RBSpacing.sm)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .stepContextMenu(step: step, job: job, onTap: onTap)
    }
    /// Resolves the foreground color for the step’s conclusion icon based on its conclusion and status.
    private var iconColor: Color {
        switch step.conclusion {
        case .success:                   return Color.rbSuccess
        case .failure:                   return Color.rbDanger
        case .skipped, .cancelled:       return Color.rbTextTertiary
        default: return step.status == .inProgress ? Color.rbBlue : Color.rbTextTertiary
        }
    }
}

// MARK: - JobRowCard
/// Expandable card that represents one job within a workflow run.
/// Tapping the header toggles the step list; long-press opens the job in Safari.
private struct JobRowCard: View {
    /// The job model to render.
    let job: ActiveJob
    /// Resolved `RBStatus` for this job, used to drive the `DonutStatusView`.
    let status: RBStatus
    /// True when this card is the last job in the run’s job list; affects the tree-line termination.
    let isLast: Bool
    /// The parent workflow run group; passed through to the context menu modifier.
    let group: WorkflowActionGroup
    /// Whether the step list is currently expanded for this card.
    let isExpanded: Bool
    /// Called when the user taps the job header to toggle step expansion.
    let onToggle: () -> Void
    /// Called when the user taps a step row inside the expanded step list.
    let onStepTap: (JobStep) -> Void
    // indent = 7: half of the workflow DonutStatusView dot (size 14).
    // Geometry: card colour bar(4) + clear spacer(12) + half-dot(7) = 23 from card edge.
    // InlineJobRowsView padding(.leading:12) + colour bar(4) = 16 from card edge.
    // So leader barX = 23 - 16 = 7 centers under the workflow dot.
    /// Horizontal offset aligning the job tree-line bar under the workflow’s DonutStatusView dot centre.
    private let dotIndent: CGFloat = 7
    /// Total number of steps in this job.
    private var totalSteps: Int { job.steps.count }
    /// Number of steps that have already reached a completed or concluded state.
    private var completedSteps: Int {
        job.steps.filter { $0.conclusion != nil || $0.status == .completed }.count
    }
    /// Renders the tree-line leader alongside the job header and optional step list.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TreeLineLeader(isLast: isLast && !isExpanded, indent: dotIndent)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                jobHeader
                if isExpanded { stepsContainer }
            }
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                    .fill(Color.rbSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                            .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous))
        }
        .padding(.vertical, 1)
        .jobContextMenu(job: job, group: group)
    }
    /// Tappable header row showing the job status dot, name, inline progress bar, step counter, and elapsed time.
    private var jobHeader: some View {
        Button {
            guard totalSteps > 0 else { return }
            withAnimation(.easeInOut(duration: 0.15)) { onToggle() }
        } label: {
            HStack(spacing: 6) {
                DonutStatusView(status: status, progress: job.progressFraction ?? 0, size: 10)
                Text(job.name)
                    .font(DesignTokens.Fonts.mono)
                    .foregroundColor(job.isDimmed ? Color.rbTextTertiary : Color.rbTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if job.status == .inProgress {
                    JobInlineProgress(progress: job.progressFraction ?? 0)
                        .frame(width: 120)
                }
                if totalSteps > 0 {
                    Text("\(completedSteps)/\(totalSteps)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextTertiary)
                        .fixedSize()
                }
                if job.startedAt != nil {
                    Text(job.elapsed)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextTertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, RBSpacing.sm)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    /// Vertical list of `StepRowView` items separated by a top divider; shown when the card is expanded.
    private var stepsContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.rbBorderSubtle.frame(height: 0.5)
                .padding(.horizontal, RBSpacing.sm)
            ForEach(Array(job.steps.enumerated()), id: \.element.id) { index, step in
                StepRowView(
                    step: step,
                    job: job,
                    isLast: index == job.steps.count - 1,
                    onTap: { onStepTap(step) }
                )
            }
        }
        .padding(.horizontal, RBSpacing.xs)
        .padding(.bottom, RBSpacing.xs)
    }
}

// MARK: - InlineJobRowsView
/// Vertically stacked list of `JobRowCard` views for a single workflow run.
/// Rendered inside the action row when the run is expanded.
struct InlineJobRowsView: View {
    /// The workflow run group whose jobs are rendered.
    let group: WorkflowActionGroup
    /// Monotonically incrementing tick value from the parent view; forces re-evaluation of elapsed-time labels.
    let tick: Int
    /// When true all jobs are shown; when false only in-progress jobs are rendered.
    var fullExpand: Bool = false
    // Default no-op handler; callers that need step navigation override this.
    /// Called when the user taps a step row. Receives the parent job and the tapped step.
    /// Defaults to a no-op; callers that require navigation provide a real implementation.
    var onStepTap: (ActiveJob, JobStep) -> Void = { _, _ in
        // Intentionally empty: default is a no-op.
        // Callers that require navigation provide a real implementation.
    }
    /// Tracks whether the panel is visible; the job list is only rendered while the panel is open.
    @EnvironmentObject private var panelVisibilityState: PanelVisibilityState
    /// Set of job IDs whose step lists are currently expanded.
    @State private var expandedJobIDs: Set<Int> = []
    /// Snapshot of `tick` captured at render time; used as part of each row’s stable identity
    /// so SwiftUI re-renders elapsed labels every second without forcing a full list rebuild.
    private var tickSnapshot: Int { tick }
    /// Renders the stacked job cards when the panel is open; renders nothing when closed.
    var body: some View {
        Group {
            if panelVisibilityState.isOpen {
                let jobs = fullExpand ? group.jobs : group.jobs.filter { $0.status == .inProgress }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        JobRowCard(
                            job: job,
                            status: jobStatus(for: job),
                            isLast: index == jobs.count - 1,
                            group: group,
                            isExpanded: expandedJobIDs.contains(job.id),
                            onToggle: {
                                if expandedJobIDs.contains(job.id) {
                                    expandedJobIDs.remove(job.id)
                                } else {
                                    expandedJobIDs.insert(job.id)
                                }
                            },
                            onStepTap: { step in onStepTap(job, step) }
                        )
                        .id("\(job.id)-\(tickSnapshot)")
                    }
                }
                .padding(.leading, RBSpacing.md)
                .padding(.trailing, RBSpacing.xs)
                .padding(.bottom, RBSpacing.xs)
            }
        }
    }
    /// Maps a job’s raw `conclusion` and `status` values to the `RBStatus` enum
    /// used by `DonutStatusView` and other UI components.
    private func jobStatus(for job: ActiveJob) -> RBStatus {
        if let conclusion = job.conclusion {
            switch conclusion {
            case .success:                   return .success
            case .failure:                   return .failed
            case .cancelled, .skipped:       return .unknown
            default:                         return .unknown
            }
        }
        switch job.status {
        case .inProgress: return .inProgress
        case .queued:     return .queued
        default:          return .queued
        }
    }
}
// swiftlint:enable redundant_discardable_let

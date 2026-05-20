import SwiftUI
// swiftlint:disable colon opening_brace

// MARK: - TreeLineLeader
/// L-shaped tree-line drawn with Canvas.
///
/// fix(#455-align): barX is centred under the workflow-level DonutStatusView dot.
///
/// Layout math:
///   ActionRowView.rowContent has `Color.clear.frame(width: RBSpacing.md)` on the left,
///   then `DonutStatusView(size: 14)`. Dot centre from card left edge = RBSpacing.md + 7.
///
///   InlineJobRowsView VStack has .padding(.leading, RBSpacing.md).
///   Inside that, JobRowCard HStack has TreeLineLeader as first child.
///   TreeLineLeader origin from card left = RBSpacing.md (InlineJobRowsView leading pad).
///
///   To align barX under the workflow dot centre:
///     barX (from leader origin) = (RBSpacing.md + 7) - RBSpacing.md = 7pt
///   So barX = dotRadius = 7 (half of workflow dot size 14).
///
/// fix(#455-gap): The vertical bar must draw from y=0 to y=size.height (or midY for
///   last row) with NO gap. JobRowCard sets .frame(maxHeight: .infinity) + alignment: .top
///   on the HStack, and .padding(.top, 0) on the leader (no top offset — the bar starts
///   at the very top of the leader frame and the card's .padding(.vertical, 1) provides
///   the inter-card gap at the VStack level, NOT inside the card).
private struct TreeLineLeader: View {
    let isLast: Bool
    /// barX from the leader's left edge. Set to dotRadius (7) so bar aligns under workflow dot.
    var barX: CGFloat = 7

    private let lineColor = Color.secondary.opacity(0.35)
    private let barWidth: CGFloat = 1
    private let elbowWidth: CGFloat = 8
    private let arrowSize: CGFloat = 4

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            // Vertical bar: y=0 → midY (last row) or full height (not last)
            var vertPath = Path()
            vertPath.move(to: CGPoint(x: barX, y: 0))
            vertPath.addLine(to: CGPoint(x: barX, y: isLast ? midY : size.height))
            ctx.stroke(vertPath, with: .color(lineColor), lineWidth: barWidth)
            // Horizontal elbow from barX → arrow tip
            let elbowEndX = barX + elbowWidth
            let arrowTipX = elbowEndX
            var elbowPath = Path()
            elbowPath.move(to: CGPoint(x: barX, y: midY))
            elbowPath.addLine(to: CGPoint(x: arrowTipX - arrowSize, y: midY))
            ctx.stroke(elbowPath, with: .color(lineColor), lineWidth: barWidth)
            // Arrowhead
            var arrow = Path()
            arrow.move(to: CGPoint(x: arrowTipX, y: midY))
            arrow.addLine(to: CGPoint(x: arrowTipX - arrowSize, y: midY - arrowSize / 2))
            arrow.addLine(to: CGPoint(x: arrowTipX - arrowSize, y: midY + arrowSize / 2))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(lineColor))
        }
        .frame(width: barX + elbowWidth + arrowSize + 2)
    }
}

// MARK: - JobInlineProgress
/// Inline progress capsule. fix(#419): fill is rbBlue (in-progress = blue per spec).
private struct JobInlineProgress: View {
    let progress: Double
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
/// A single step row rendered inside the expanded job container.
/// Tapping navigates to StepLogView. Right-click shows step context menu.
private struct StepRowView: View {
    let step: JobStep
    let job: ActiveJob
    let isLast: Bool
    let onTap: () -> Void

    // Step tree bar aligns under the job card's DonutStatusView(size:10) centre.
    // Job card has .padding(.horizontal, RBSpacing.sm) so dot centre from step-leader
    // origin = RBSpacing.sm + 5. The step leader starts right after the job-leader frame.
    // Keep simple: same barX=5 so step elbow feels consistent.
    private let stepBarX: CGFloat = 5

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TreeLineLeader(isLast: isLast, barX: stepBarX)
                .frame(maxHeight: .infinity)
            stepContent
        }
    }

    private var stepContent: some View {
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
            if step.status == "in_progress" || step.conclusion != nil {
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
        .onTapGesture { onTap() }
        .stepContextMenu(step: step, job: job, onTap: onTap)
    }

    private var iconColor: Color {
        switch step.conclusion {
        case "success":              return Color.rbSuccess
        case "failure":              return Color.rbDanger
        case "skipped", "cancelled": return Color.rbTextTertiary
        default:                     return step.status == "in_progress" ? Color.rbBlue : Color.rbTextTertiary
        }
    }
}

// MARK: - JobRowCard
/// Single job row with optional inline step expansion.
/// fix(#455): job header + step rows share ONE background container.
/// fix(#578): isExpanded owned by parent (expandedJobIDs) so ticks don't reset it.
/// fix(#455-tree): TreeLineLeader .frame(maxHeight: .infinity) so bar spans full expanded height.
/// fix(#455-align): HStack alignment: .top + NO .padding(.top) on leader so bar starts at y=0
///   of the card frame and connects seamlessly to the bar from the card above.
private struct JobRowCard: View {
    let job: ActiveJob
    let status: RBStatus
    let isLast: Bool
    let group: ActionGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    let onStepTap: (JobStep) -> Void

    private var totalSteps: Int { job.steps.count }
    private var completedSteps: Int {
        job.steps.filter { $0.conclusion != nil || $0.status == "completed" }.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // fix(#455-tree): maxHeight .infinity — bar spans the whole expanded card.
            // fix(#455-align): no .padding(.top) — bar starts at y=0 of the HStack frame
            //   so it connects with zero gap to the card above.
            TreeLineLeader(isLast: isLast && !isExpanded)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                jobHeader
                if isExpanded {
                    stepsContainer
                }
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
        // fix(#455-gap): vertical spacing between job cards managed by VStack spacing=2
        // in InlineJobRowsView, NOT by per-card padding, so the tree line is continuous.
        .jobContextMenu(job: job, group: group)
    }

    private var jobHeader: some View {
        HStack(spacing: 6) {
            DonutStatusView(status: status, progress: job.progressFraction ?? 0, size: 10)
            Text(job.name)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(job.isDimmed ? Color.rbTextTertiary : Color.rbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if job.status == "in_progress" {
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
        .onTapGesture {
            guard totalSteps > 0 else { return }
            withAnimation(.easeInOut(duration: 0.15)) { onToggle() }
        }
    }

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
/// Collapsed sub-row list shown beneath an ActionRowView when expanded.
///
/// Phase 4 spec (#420): inline job rows are read-only / passive context.
///
/// Expand behaviour (fix #419):
///   - Default (auto-expand for in-progress): shows ONLY in_progress jobs.
///   - After user taps the workflow row (fullExpand): shows ALL jobs.
///
/// #455: Each job row expands to show steps inside the same background container.
/// fix(#578): expandedJobIDs owned here so ticks don't reset expand state.
///
/// ⚠️ REGRESSION GUARD #377 — DO NOT REMOVE @EnvironmentObject popoverState:
/// This view must not render while the popover is hidden.
struct InlineJobRowsView: View {
    let group: ActionGroup
    let tick: Int
    var fullExpand: Bool = false
    var onStepTap: (ActiveJob, JobStep) -> Void = { _, _ in }

    @EnvironmentObject private var popoverState: PopoverOpenState
    @State private var expandedJobIDs: Set<Int> = []

    private var tickSnapshot: Int { tick }

    var body: some View {
        // ⚠️ REGRESSION GUARD #377 — do not remove this check.
        Group {
            if popoverState.isOpen {
                let jobs = fullExpand
                    ? group.jobs
                    : group.jobs.filter { $0.status == "in_progress" }
                // fix(#455-gap): spacing=0 between job cards so the TreeLineLeader
                // vertical bars from consecutive cards are perfectly adjacent with no gap.
                // The visual separation between cards is provided by the card background
                // (rounded rect border) only, not by spacing.
                VStack(alignment: .leading, spacing: 0) {
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

    private func jobStatus(for job: ActiveJob) -> RBStatus {
        if let conclusion = job.conclusion {
            switch conclusion {
            case "success":              return .success
            case "failure":              return .failed
            case "cancelled", "skipped": return .unknown
            default:                     return .unknown
            }
        }
        switch job.status {
        case "in_progress": return .inProgress
        case "queued":      return .queued
        default:            return .queued
        }
    }
}

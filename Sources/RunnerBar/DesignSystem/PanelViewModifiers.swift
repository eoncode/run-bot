// PanelViewModifiers.swift
// RunnerBar
import SwiftUI

// MARK: - StatPill
/// Compact ultraThinMaterial pill showing a label + value (e.g. "CPU 3.2%").
/// Used in PanelLocalRunnerRow to surface per-runner CPU / MEM metrics.
struct StatPill: View {
    /// The short metric label (e.g. "CPU", "MEM").
    let label: String
    /// The formatted metric value (e.g. "3.6%").
    let value: String

    /// Lays out the label and value side-by-side inside a material capsule.
    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(RBFont.statLabel)
                .foregroundColor(.secondary)
            Text(value)
                .font(RBFont.statValue)
                .foregroundColor(.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - StatusBadge
/// Capsule-stroked badge used in action-row trailing area.
/// Renders a colour-matched border + label for a given RBStatus.
struct StatusBadge: View {
    /// The status that drives the badge colour.
    let status: RBStatus
    /// The text displayed inside the badge.
    let text: String

    /// Renders the status text inside a colour-matched capsule stroke.
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(status.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .strokeBorder(status.color.opacity(0.5), lineWidth: 1)
            )
    }
}

// MARK: - BranchTagPill
/// Inline pill displaying a git branch or tag name.
/// Uses a blue-tinted stroke capsule consistent with the Phase 5 design language.
struct BranchTagPill: View { // periphery:ignore
    /// The branch or tag name to display.
    let name: String

    /// Renders the branch icon and name inside a tinted capsule stroke.
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8, weight: .medium))
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(Color.rbAccent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - GlassCard
/// Central ViewModifier for Liquid Glass card surfaces.
///
/// On macOS 26+ applies `.glassEffect(.regular.interactive())`.
/// On older OSes falls back to `.ultraThinMaterial` + a subtle white stroke overlay.
///
/// ⚠️ No other file should call `.glassEffect()` or `.ultraThinMaterial`
/// directly on card/section containers — always use `.glassCard()` or `.glassSection()`.
///
/// - Note: `StatPill` is intentionally excluded — it is a Capsule-shaped inline
///   metric pill, not a card container, and retains its own `.ultraThinMaterial` capsule.
struct GlassCard: ViewModifier {
    /// Corner radius matching `DesignTokens` card tokens (default: 10 pt).
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        }
    }
}

extension View {
    /// Applies the `GlassCard` modifier with an optional corner radius override.
    ///
    /// Use this on any card/container surface. Default radius is 10 pt;
    /// pass `cornerRadius: 8` for tighter row-level containers.
    func glassCard(cornerRadius: CGFloat = 10) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

// MARK: - GlassSection
/// Prominent Liquid Glass modifier for section headers and elevated containers.
///
/// On macOS 26+ applies `.glassEffect(.prominent)`.
/// On older OSes falls back to `.thinMaterial` + a subtle white stroke overlay.
struct GlassSection: ViewModifier {
    /// Corner radius matching `DesignTokens` section tokens (default: 10 pt).
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(
                    .prominent,
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(
                    .thinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                )
        }
    }
}

extension View {
    /// Applies the `GlassSection` modifier for section headers and elevated containers.
    func glassSection(cornerRadius: CGFloat = 10) -> some View {
        modifier(GlassSection(cornerRadius: cornerRadius))
    }
}

// MARK: - Previews
#if DEBUG
#Preview("StatPill") {
    HStack(spacing: 8) {
        StatPill(label: "CPU", value: "3.6%")
        StatPill(label: "MEM", value: "0.2%")
    }
    .padding()
}

#Preview("StatusBadge") {
    VStack(spacing: 8) {
        StatusBadge(status: .inProgress, text: "IN PROGRESS")
        StatusBadge(status: .success, text: "SUCCESS")
        StatusBadge(status: .failed, text: "FAILED")
        StatusBadge(status: .queued, text: "QUEUED")
    }
    .padding()
}

#Preview("BranchTagPill") {
    VStack(spacing: 8) {
        BranchTagPill(name: "feat/redesign-phases-1-5")
        BranchTagPill(name: "main")
    }
    .padding()
}

#Preview("GlassCard") {
    VStack(spacing: 12) {
        Text("GlassCard (default r=10)")
            .padding()
            .glassCard()
        Text("GlassCard (r=8, row variant)")
            .padding()
            .glassCard(cornerRadius: 8)
    }
    .padding()
    .frame(width: 300)
}

#Preview("GlassSection") {
    Text("GlassSection header")
        .padding()
        .glassSection()
        .padding()
        .frame(width: 300)
}
#endif

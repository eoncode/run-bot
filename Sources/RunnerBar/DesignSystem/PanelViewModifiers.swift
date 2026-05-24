// PanelViewModifiers.swift
// RunnerBar
import SwiftUI

// MARK: - GlassCard macOS 26 core (compile-time availability guard)

/// Internal macOS 26-only modifier that calls `.glassEffect(.regular.interactive())`.
/// Only referenced through `GlassCard.body` behind a runtime `#available` check.
@available(macOS 26, *)
private struct GlassCardMacOS26: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape.
    var cornerRadius: CGFloat
    /// Applies `.glassEffect(.regular.interactive())` on macOS 26+.
    func body(content: Content) -> some View {
        content
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

// MARK: - GlassSection macOS 26 core (compile-time availability guard)

/// Internal macOS 26-only modifier that calls `.glassEffect(.prominent)`.
/// Only referenced through `GlassSection.body` behind a runtime `#available` check.
@available(macOS 26, *)
private struct GlassSectionMacOS26: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape.
    var cornerRadius: CGFloat
    /// Applies `.glassEffect(.prominent)` on macOS 26+.
    func body(content: Content) -> some View {
        content
            .glassEffect(
                .prominent,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

// MARK: - GlassCard
/// Centralised Liquid Glass card modifier.
/// On macOS 26+ uses `.glassEffect(.regular.interactive())`;
/// on older OSes falls back to `.ultraThinMaterial` + a subtle stroke overlay.
///
/// All phases of the Liquid Glass adoption (Phase 3–7) must use `.glassCard()`
/// instead of calling `.glassEffect()` or `.ultraThinMaterial` directly on
/// card containers.
///
/// ❌ Do NOT convert `StatPill` to `GlassCard` — it is a capsule-shaped inline
/// pill, not a card container.
struct GlassCard: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to
    /// `RBRadius.card` (8 pt).
    var cornerRadius: CGFloat = RBRadius.card

    /// Applies Liquid Glass on macOS 26+ and a material fallback on older OSes.
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            AnyView(content.modifier(GlassCardMacOS26(cornerRadius: cornerRadius)))
        } else {
            AnyView(
                content
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                    )
            )
        }
    }
}

// MARK: - GlassSection
/// Prominent Liquid Glass modifier intended for section headers and containers.
/// On macOS 26+ uses `.glassEffect(.prominent)`;
/// on older OSes falls back to `.ultraThinMaterial` + a heavier stroke overlay.
struct GlassSection: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to
    /// `RBRadius.card` (8 pt).
    var cornerRadius: CGFloat = RBRadius.card

    /// Applies prominent Liquid Glass on macOS 26+ and a material fallback on older OSes.
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            AnyView(content.modifier(GlassSectionMacOS26(cornerRadius: cornerRadius)))
        } else {
            AnyView(
                content
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                    )
            )
        }
    }
}

// MARK: - View extensions
extension View {
    /// Applies the `GlassCard` modifier to this view.
    /// - Parameter cornerRadius: Corner radius of the glass shape.
    ///   Defaults to `RBRadius.card` (8 pt).
    func glassCard(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    /// Applies the `GlassSection` modifier to this view.
    /// - Parameter cornerRadius: Corner radius of the glass shape.
    ///   Defaults to `RBRadius.card` (8 pt).
    func glassSection(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassSection(cornerRadius: cornerRadius))
    }
}

// MARK: - StatPill
/// Compact ultraThinMaterial pill showing a label + value (e.g. "CPU 3.2%").
/// Used in PanelLocalRunnerRow to surface per-runner CPU / MEM metrics.
/// ❌ Do NOT convert to GlassCard — this is a capsule-shaped inline pill,
/// not a card container.
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

// MARK: - Previews
#if DEBUG
#Preview("GlassCard") {
    VStack(spacing: 12) {
        Text("Glass Card")
            .padding()
            .glassCard()
        Text("Glass Card r=8")
            .padding()
            .glassCard(cornerRadius: 8)
    }
    .padding()
}

#Preview("GlassSection") {
    Text("Section Header")
        .padding()
        .glassSection()
        .padding()
}

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
#endif

// PanelViewModifiers.swift
// RunnerBar
//
// COEXISTENCE CONTRACT: CardRowModifier vs GlassCard/GlassSection
// ─────────────────────────────────────────────────────────────────
//  CardRowModifier  — flat semi-transparent fill for SCROLLABLE list rows
//                    (Apple HIG: ❌ NEVER glass on scrollable content)
//  GlassCard        — Liquid Glass for NON-SCROLLABLE floating card containers
//  GlassSection     — stronger Liquid Glass for section headers/containers
//
// These two idioms serve different layout contexts and must coexist.
// ❌ NEVER replace CardRowModifier with GlassCard on list rows.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
import SwiftUI

// MARK: - CardRowModifier

/// Flat semi-transparent card background for rows inside scrollable lists.
///
/// Apple HIG prohibits `.glassEffect` on scrollable list content — use this
/// modifier for list rows and `GlassCard` for floating non-scrollable containers.
///
/// ❌ NEVER apply `.glassEffect` here.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
struct CardRowModifier: ViewModifier {
    /// When `true`, uses `rbSurfaceElevated` fill; otherwise uses `rbSurface`.
    var elevated: Bool

    /// Creates a `CardRowModifier`.
    /// - Parameter elevated: Use elevated surface colour. Defaults to `false`.
    init(elevated: Bool = false) {
        self.elevated = elevated
    }

    /// Applies a semi-transparent rounded rectangle fill.
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                    .fill(elevated ? Color.rbSurfaceElevated : Color.rbSurface)
            )
    }
}

// MARK: - GlassCard
/// Centralised Liquid Glass card modifier.
/// On macOS 26+ (Swift 6.2+) uses `.glassEffect(.regular.interactive())`;
/// on older OSes falls back to `.ultraThinMaterial` + a subtle stroke overlay.
///
/// All phases of the Liquid Glass adoption (Phase 3–7) must use `.glassCard()`
/// instead of calling `.glassEffect()` or `.ultraThinMaterial` directly on
/// card containers.
///
/// ❌ Do NOT convert `StatPill` to `GlassCard` — it is a capsule-shaped inline
/// pill, not a card container.
struct GlassCard: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.card` (8 pt).
    var cornerRadius: CGFloat
    /// Opacity of the fallback stroke border. Defaults to 0.15 (card); use 0.25 for sections.
    var strokeOpacity: Double

    /// Creates a `GlassCard` modifier.
    /// - Parameters:
    ///   - cornerRadius: Corner radius of the glass shape. Defaults to `RBRadius.card`.
    ///   - strokeOpacity: Stroke opacity used in the material fallback. Defaults to `0.15`.
    init(cornerRadius: CGFloat = RBRadius.card, strokeOpacity: Double = 0.15) {
        self.cornerRadius = cornerRadius
        self.strokeOpacity = strokeOpacity
    }

    /// Applies Liquid Glass on macOS 26+ and a material fallback on older OSes.
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            AnyView(
                content.glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            )
        } else {
            AnyView(materialFallback(content: content))
        }
    }

    /// Returns the `.ultraThinMaterial` + stroke fallback view used on macOS < 26.
    private func materialFallback(content: Content) -> some View {
        content
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 0.5)
            )
    }
}

// MARK: - GlassSection
/// Prominent Liquid Glass modifier intended for section headers and containers.
/// Delegates to `GlassCard` with a stronger stroke opacity (0.25) to distinguish
/// section containers from regular cards.
struct GlassSection: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.card` (8 pt).
    var cornerRadius: CGFloat

    /// Creates a `GlassSection` modifier.
    /// - Parameter cornerRadius: Corner radius of the glass shape. Defaults to `RBRadius.card`.
    init(cornerRadius: CGFloat = RBRadius.card) {
        self.cornerRadius = cornerRadius
    }

    /// Applies interactive Liquid Glass on macOS 26+ and a material fallback on older OSes.
    func body(content: Content) -> some View {
        content.modifier(GlassCard(cornerRadius: cornerRadius, strokeOpacity: 0.25))
    }
}

// MARK: - GlassButton
/// Liquid Glass interactive button modifier.
/// On macOS 26+ (Swift 6.2+) wraps the content in a `GlassEffectContainer`
/// and applies `.glassEffect(.regular.interactive())`; on older OSes returns
/// the content unstyled (buttons already carry their own `.buttonStyle`).
///
/// Use `.glassButton()` on any tappable button-style view instead of calling
/// `.glassEffect(.regular.interactive())` directly.
struct GlassButton: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to
    /// `RBRadius.small` (4 pt).
    var cornerRadius: CGFloat

    /// Creates a `GlassButton` modifier.
    /// - Parameter cornerRadius: Corner radius of the glass shape. Defaults to `RBRadius.small`.
    init(cornerRadius: CGFloat = RBRadius.small) {
        self.cornerRadius = cornerRadius
    }

    /// Wraps the content in a Liquid Glass interactive container on macOS 26+;
    /// passes through unstyled on older OSes.
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            AnyView(
                GlassEffectContainer {
                    content
                        .glassEffect(
                            .regular.interactive(),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                }
            )
        } else {
            AnyView(content)
        }
    }
}

// MARK: - Pill background modifiers (private)

/// Background modifier for `StatPill`.
/// macOS 26+: `.glassEffect(.regular, in: Capsule())`.
/// macOS < 26: `.background(.ultraThinMaterial, in: Capsule())` (unchanged).
private struct StatPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Background modifier for `StatusBadge`.
/// macOS 26+: tinted fill + `.glassEffect(.regular, in: Capsule())`.
/// macOS < 26: `Capsule().strokeBorder(color.opacity(0.5))` (unchanged).
private struct StatusBadgeBackground: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(color.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(
                    Capsule()
                        .strokeBorder(color.opacity(0.5), lineWidth: 1)
                )
        }
    }
}

/// Background modifier for `BranchTagPill`.
/// macOS 26+: accent tinted fill + `.glassEffect(.regular, in: Capsule())`.
/// macOS < 26: `Capsule().strokeBorder(rbAccent.opacity(0.4))` (unchanged).
private struct BranchTagPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Color.rbAccent.opacity(0.12), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(
                    Capsule()
                        .strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 1)
                )
        }
    }
}

// MARK: - View extensions
/// Convenience modifiers for applying Liquid Glass effects to any `View`.
extension View {
    /// Applies the `CardRowModifier` to this view.
    /// - Parameter elevated: Use elevated surface colour. Defaults to `false`.
    func cardRow(elevated: Bool = false) -> some View {
        modifier(CardRowModifier(elevated: elevated))
    }

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

    /// Applies the `GlassButton` modifier to this view.
    /// - Parameter cornerRadius: Corner radius of the glass shape.
    ///   Defaults to `RBRadius.small` (4 pt).
    func glassButton(cornerRadius: CGFloat = RBRadius.small) -> some View {
        modifier(GlassButton(cornerRadius: cornerRadius))
    }
}

// MARK: - StatPill
/// Compact glass pill showing a label + value (e.g. "CPU 3.2%").
/// Used in PanelLocalRunnerRow to surface per-runner CPU / MEM metrics.
///
/// macOS 26+: `.glassEffect(.regular, in: Capsule())` via `StatPillBackground`.
/// macOS < 26: `.background(.ultraThinMaterial, in: Capsule())` (unchanged).
///
/// ❌ Do NOT convert to GlassCard — this is a capsule-shaped inline pill,
/// not a card container.
struct StatPill: View {
    /// The short metric label (e.g. "CPU", "MEM").
    let label: String
    /// The formatted metric value (e.g. "3.6%").
    let value: String

    /// Lays out the label and value side-by-side inside a glass/material capsule.
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
        .modifier(StatPillBackground())
    }
}

// MARK: - StatusBadge
/// Capsule badge used in action-row trailing area.
///
/// macOS 26+: tinted fill + `.glassEffect(.regular, in: Capsule())` via
/// `StatusBadgeBackground`.
/// macOS < 26: colour-matched `Capsule().strokeBorder` (unchanged).
struct StatusBadge: View {
    /// The status that drives the badge colour.
    let status: RBStatus
    /// The text displayed inside the badge.
    let text: String

    /// Renders the status text inside an OS-appropriate capsule background.
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(status.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .modifier(StatusBadgeBackground(color: status.color))
    }
}

// MARK: - BranchTagPill
/// Inline pill displaying a git branch or tag name.
///
/// macOS 26+: accent-tinted fill + `.glassEffect(.regular, in: Capsule())` via
/// `BranchTagPillBackground`.
/// macOS < 26: blue-tinted `Capsule().strokeBorder` (unchanged).
struct BranchTagPill: View { // periphery:ignore
    /// The branch or tag name to display.
    let name: String

    /// Renders the branch icon and name inside an OS-appropriate capsule background.
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
        .modifier(BranchTagPillBackground())
    }
}

// MARK: - Previews
#if DEBUG
#Preview("CardRow") {
    VStack(spacing: 8) {
        Text("Normal row")
            .padding()
            .cardRow()
        Text("Elevated row")
            .padding()
            .cardRow(elevated: true)
    }
    .padding()
}

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

#Preview("GlassButton") {
    Button(action: { /* preview stub — no action needed */ }) {
        Text("Re-run")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
    .glassButton()
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

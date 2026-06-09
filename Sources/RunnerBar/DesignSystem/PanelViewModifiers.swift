// PanelViewModifiers.swift
// RunnerBar
import SwiftUI

// MARK: - GlassCard
/// Centralised Liquid Glass card modifier.
/// On macOS 26+ uses `.glassEffect(.regular)` — passive containers must NOT
/// use `.interactive()`. The LiquidGlassReference guide restricts `.interactive()`
/// to tappable controls (buttons, icons) only. Applying it to a passive container
/// activates scaling/shimmer on the entire card surface including non-interactive
/// children, which is semantically wrong and wastes GPU compositing budget.
/// Tappable rows handle interactivity at the contentShape/button level via GlassButton.
/// On older OSes falls back to `.ultraThinMaterial` + a subtle stroke overlay.
///
/// All phases of the Liquid Glass adoption (Phase 3–7) must use `.glassCard()`
/// instead of calling `.glassEffect()` or `.ultraThinMaterial` directly on
/// card containers.
///
/// ❌ Do NOT convert `StatPill` to `GlassCard` — it is a capsule-shaped inline
/// pill, not a card container. Use `StatPillBackground` instead.
/// ❌ Do NOT add `.interactive()` back to GlassCard — see #963.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat
    var strokeOpacity: Double
    init(cornerRadius: CGFloat = RBRadius.card, strokeOpacity: Double = 0.15) {
        self.cornerRadius = cornerRadius
        self.strokeOpacity = strokeOpacity
    }
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 0.5)
                )
        } else {
            materialFallback(content: content)
        }
    }
    private func materialFallback(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 0.5)
            )
    }
}

// MARK: - GlassSection
struct GlassSection: ViewModifier {
    var cornerRadius: CGFloat
    init(cornerRadius: CGFloat = RBRadius.card) { self.cornerRadius = cornerRadius }
    func body(content: Content) -> some View {
        content.modifier(GlassCard(cornerRadius: cornerRadius, strokeOpacity: 0.25))
    }
}

// MARK: - GlassButton
/// ❌ Do NOT call `.glassEffect(.regular.interactive())` directly on buttons.
struct GlassButton: ViewModifier {
    var cornerRadius: CGFloat
    init(cornerRadius: CGFloat = RBRadius.small) { self.cornerRadius = cornerRadius }
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
        }
    }
}

// MARK: - StatPillBackground
/// Background modifier for `StatPill` and `RunnerMetricsBadge` capsule pills.
///
/// macOS 26+: identical architecture to `DiskPillBadge`:
///   `Color.white.opacity(0.15)` tint — bleeds through the glass refractive
///   layer and defines the pill edge visually, exactly as coloured pills do.
///   `Color.primary` was wrong — it resolves to near-black in dark mode,
///   making the tint invisible and leaving the glass nothing to refract.
///
/// The call site MUST wrap `RunnerMetricsBadge` in its OWN `GlassEffectContainer`
/// (separate from the card container) — same pattern as `DiskPillBadge` in
/// `HeaderStatsBar` and `StatusBadge` in `metaTrailing`.
///
/// macOS < 26: `.ultraThinMaterial` in a `Capsule()` (unchanged).
///
/// ❌ Do NOT revert tint to `Color.primary` — it is near-black in dark mode.
struct StatPillBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Color.white.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - StatusBadgeBackground
/// colour tint + glass — identical pattern to DiskPillBadge.
/// Call site MUST wrap in GlassEffectContainer.
struct StatusBadgeBackground: ViewModifier {
    let color: Color
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(color.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(color.opacity(0.25), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 0.5))
        }
    }
}

// MARK: - BranchTagPillBackground
struct BranchTagPillBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Color.rbAccent.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 1))
        }
    }
}

// MARK: - CardRowModifier
/// ❌ NEVER apply `.glassEffect` here.
/// Apple HIG: glass effects must not be applied to scrollable list content —
/// they break CABackdropLayer sampling and cause visual artefacts during scroll.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
struct CardRowModifier: ViewModifier {
    var elevated: Bool = false
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(elevated ? Color.rbSurfaceElevated : Color.rbSurface)
        )
    }
}

// MARK: - View extensions
extension View {
    func glassCard(cornerRadius: CGFloat = RBRadius.card) -> some View { modifier(GlassCard(cornerRadius: cornerRadius)) }
    func glassSection(cornerRadius: CGFloat = RBRadius.card) -> some View { modifier(GlassSection(cornerRadius: cornerRadius)) }
    func glassButton(cornerRadius: CGFloat = RBRadius.small) -> some View { modifier(GlassButton(cornerRadius: cornerRadius)) }
    /// ⚠️ Call site MUST wrap RunnerMetricsBadge in its OWN GlassEffectContainer on macOS 26+.
    func statPillBackground() -> some View { modifier(StatPillBackground()) }
    /// ⚠️ Call site MUST wrap badge in a GlassEffectContainer on macOS 26+.
    func statusBadgeBackground(color: Color) -> some View { modifier(StatusBadgeBackground(color: color)) }
    func branchTagPillBackground() -> some View { modifier(BranchTagPillBackground()) }
    /// ❌ NEVER add `.glassEffect` to this modifier.
    func cardRow(elevated: Bool = false) -> some View { modifier(CardRowModifier(elevated: elevated)) }
}

// MARK: - StatPill
/// ❌ Do NOT convert to GlassCard — capsule pill, not a card container.
struct StatPill: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(RBFont.statLabel).foregroundColor(.secondary)
            Text(value).font(RBFont.statValue).foregroundColor(.primary).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .statPillBackground()
    }
}

// MARK: - StatusBadge
/// ⚠️ Must be wrapped in a GlassEffectContainer at call site.
struct StatusBadge: View {
    let status: RBStatus
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(status.color)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .statusBadgeBackground(color: status.color)
    }
}

// MARK: - BranchTagPill
struct BranchTagPill: View { // periphery:ignore — used dynamically inside ActionRowView.rowContent
    let name: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .medium))
            Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundColor(Color.rbAccent)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .branchTagPillBackground()
    }
}

// MARK: - Previews
#if DEBUG
#Preview("GlassCard") {
    VStack(spacing: 12) {
        Text("Glass Card").padding().glassCard()
        Text("Glass Card r=10").padding().glassCard(cornerRadius: 10)
    }.padding()
}
#Preview("GlassSection") { Text("Section Header").padding().glassSection().padding() }
#Preview("GlassButton") {
    Button(action: {}) { Text("Re-run").font(.caption).padding(.horizontal, 8).padding(.vertical, 4) }
        .buttonStyle(.plain).glassButton().padding()
}
#Preview("StatPill") {
    HStack(spacing: 8) { StatPill(label: "CPU", value: "3.6%"); StatPill(label: "MEM", value: "0.2%") }.padding()
}
#Preview("StatusBadge") {
    VStack(spacing: 8) {
        StatusBadge(status: .inProgress, text: "IN PROGRESS")
        StatusBadge(status: .success, text: "SUCCESS")
        StatusBadge(status: .failed, text: "FAILED")
        StatusBadge(status: .queued, text: "QUEUED")
    }.padding()
}
#Preview("BranchTagPill") {
    VStack(spacing: 8) {
        BranchTagPill(name: "feat/redesign-phases-1-5")
        BranchTagPill(name: "main")
    }.padding()
}
#Preview("CardRowModifier") {
    VStack(spacing: 8) {
        Text("Standard row").padding().cardRow()
        Text("Elevated row").padding().cardRow(elevated: true)
    }.padding()
}
#endif

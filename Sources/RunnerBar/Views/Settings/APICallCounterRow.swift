// APICallCounterRow.swift
// RunnerBar
//
// Settings row that shows live GitHub REST API usage as
// `410 / 5,000  ████░░░░░░` with colour-coded progress (P5 — Liquid Glass).
import RunnerBarCore
import SwiftUI

/// A Settings row that displays the number of GitHub REST API calls made in
/// the last rolling 60-minute window alongside a colour-coded progress indicator.
///
/// Drop this view into the GitHub section of the Settings panel:
/// ```swift
/// APICallCounterRow()
/// ```
///
/// - Note: Each appearance of this view creates its own `APICallCounterViewModel`
///   and polling task via `@State`. This is correct for a single Settings row.
///   Do **not** embed this view in a `List` or `ForEach` — each cell would
///   spawn an independent 5-second polling loop.
struct APICallCounterRow: View {
    /// View-model powering this row. A new instance is created per row appearance.
    @State private var vm = APICallCounterViewModel()

    /// The view body.
    var body: some View {
        HStack(spacing: 12) {
            Text("API calls (last 60 min)")
                .foregroundStyle(.secondary)
            Spacer()
            Text(vm.label)
                .monospacedDigit()
                .foregroundStyle(vm.statusColor)
            ProgressView(value: vm.snap.fraction)
                .tint(vm.statusColor)
                .frame(width: 80)
                .animation(.easeInOut, value: vm.snap.fraction)
        }
        .padding(.vertical, 2)
        .help(
            "GitHub allows 5,000 authenticated REST calls per rolling hour. " +
            "Current usage: \(Int(vm.snap.fraction * 100))%. " +
            "Only successful calls are counted. " +
            "Paginated fetches count as 1 call regardless of page count — " +
            "real quota usage may be higher for list endpoints."
        )
    }
}

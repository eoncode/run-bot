// APICallCounterRow.swift
// RunnerBar
//
// SwiftUI Settings row displaying the live GitHub REST API call counter.
import SwiftUI
import RunnerBarCore

// MARK: - CounterPollingModifier

/// Starts the counter's polling loop when the modified view appears and
/// stops it when the view disappears, so the background Task only runs
/// while the Settings panel is on screen.
private struct CounterPollingModifier: ViewModifier {
    let vm: APICallCounterViewModel
    func body(content: Content) -> some View {
        content
            .onAppear { vm.startPolling() }
            .onDisappear { vm.stopPolling() }
    }
}

extension View {
    /// Binds the `APICallCounterViewModel` polling lifecycle to this view's
    /// appearance. Polling starts on `onAppear` and stops on `onDisappear`.
    ///
    /// Marked `public` so that app-layer views outside `RunnerBar` can wire
    /// the lifecycle when `APICallCounterRow` is embedded in a custom parent.
    public func counterPolling(_ vm: APICallCounterViewModel) -> some View {
        modifier(CounterPollingModifier(vm: vm))
    }
}

// MARK: - APICallCounterRow

/// Settings row that shows `"410 / 5,000"` with a colour-coded progress bar.
///
/// **Not yet wired into the Settings panel** — left for a follow-up app-layer
/// PR to keep this PR focused on the core implementation and tests.
///
/// Usage:
/// ```swift
/// APICallCounterRow()
/// ```
public struct APICallCounterRow: View {
    @State private var vm = APICallCounterViewModel()

    public init() {}

    public var body: some View {
        HStack {
            Text("API Calls (last hour)")
            Spacer()
            Text(vm.label)
                .foregroundStyle(vm.statusColor)
                .monospacedDigit()
            ProgressView(value: vm.snap.fraction)
                .frame(width: 60)
                .tint(vm.statusColor)
        }
        .help(
            """
            GitHub REST calls in the last 60 minutes.
            Limit resets on a rolling basis.
            Paginated fetches count as 1 call regardless of page count.
            Only successful (non-nil) calls are counted.
            """
        )
        .counterPolling(vm)
    }
}

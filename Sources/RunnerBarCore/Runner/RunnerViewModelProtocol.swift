// RunnerViewModelProtocol.swift
// RunnerBarCore
import Foundation

// MARK: - RunnerViewModelProtocol

/// Push-receiver interface through which `LocalRunnerStore` delivers
/// its computed snapshots to the main-actor presentation layer.
///
/// The five GitHub API props (`runners`, `jobs`, `actions`, `isRateLimited`,
/// `rateLimitResetDate`) moved to `RunnerState` in Step 3 and are no longer
/// part of this protocol (removed in Step 15).
///
/// Declaring the protocol in `RunnerBarCore` (rather than the app target) achieves two goals:
/// 1. `RunnerPoller` and `LocalRunnerStore` can reference it without importing AppKit or SwiftUI.
/// 2. Test doubles (`MockRunnerViewModel`) can be defined inside `RunnerBarCoreTests` and
///    passed into the actors without any app-target dependency.
///
/// **Direction of data flow:** stores *push* into the receiver; the receiver never pulls.
/// All mutations arrive on `@MainActor` via `await MainActor.run { }`.
///
/// ## Why `{ get set }` and not `{ get }`
/// `LocalRunnerStore` writes into both properties through the fully-erased
/// `any RunnerViewModelProtocol` existential. Swift only allows writes through an
/// existential when the protocol requirement is declared `{ get set }`. The setter
/// is therefore intentional — it is the entire push mechanism.
///
/// `RunnerState` uses `public internal(set) var` for both, so the setter
/// is module-internal only: the `RunnerBar` app layer cannot write them directly.
/// The protocol advertising `{ get set }` is not in conflict with that restriction
/// because `RunnerState` and `LocalRunnerStore` are both in `RunnerBarCore`.
@MainActor
public protocol RunnerViewModelProtocol: AnyObject, Sendable {
    // MARK: Pushed by LocalRunnerStore

    /// Locally-installed runner agents discovered on this Mac.
    /// `{ get set }` is required — `LocalRunnerStore` writes via the existential.
    var localRunners: [RunnerModel] { get set }
    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    /// `{ get set }` is required — `LocalRunnerStore` writes via the existential.
    var isLocalScanning: Bool { get set }
}

// MARK: - RunnerState conformance

/// `RunnerState` satisfies `RunnerViewModelProtocol` with no additional implementation:
/// it owns `localRunners` and `isLocalScanning` directly as `public internal(set) var`.
///
/// `public internal(set)` satisfies a `{ get set }` protocol requirement **within the
/// module** because the module-internal setter is visible to the compiler here.
/// External callers in the `RunnerBar` app layer see only `get` — the setter is not
/// exported — which is the encapsulation this PR intends.
extension RunnerState: RunnerViewModelProtocol {}

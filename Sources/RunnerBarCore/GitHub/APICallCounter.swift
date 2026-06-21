// APICallCounter.swift
// RunnerBarCore
//
// Tracks GitHub REST call timestamps in a rolling 60-minute window.
// Mirrors the RateLimitActor pattern (P16 — Actor-Per-Concern Isolation).
//
// Actor chosen over Mutex: record() performs an append + slice on a [Date]
// array that can reach 5,000 entries under load — non-trivial work that must
// not block a cooperative thread pool worker under a lock.
// GitHubTokenCache uses Mutex for a single pointer swap (P13 reach goal);
// this case does not qualify because the critical section is not O(1).
import Foundation

// MARK: - APICallCounterSnapshot

/// Atomic snapshot of API call-counter state returned by `APICallCounterProtocol.snapshot()`.
public struct APICallCounterSnapshot: Sendable, Equatable {
    /// Number of GitHub REST calls made in the last rolling 60-minute window.
    public let count: Int
    /// GitHub authenticated REST rate limit per rolling hour.
    public let limit: Int
    /// Fraction of the hourly limit consumed, clamped to `[0, 1]`.
    ///
    /// - Returns `0.0` when `limit == 0` to avoid `NaN` propagation.
    /// - Lower-bounded at `0.0` so a negative `count` (possible via the
    ///   public `init`) cannot produce a negative fraction.
    public var fraction: Double {
        guard limit > 0 else { return 0.0 }
        return max(0.0, min(Double(count) / Double(limit), 1.0))
    }

    /// Creates a new snapshot.
    public init(count: Int, limit: Int) {
        self.count = count
        self.limit = limit
    }
}

// MARK: - APICallCounterProtocol

/// Injectable abstraction over `APICallCounter` for deterministic testing (P7).
public protocol APICallCounterProtocol: Actor {
    /// Record one GitHub REST API call.
    func record()
    /// Returns `count` and `limit` in a single actor hop (P10).
    func snapshot() -> APICallCounterSnapshot
}

// MARK: - APICallCounter

/// Actor-isolated ring buffer of GitHub REST call timestamps.
///
/// `record()` is called once per successful `ghAPI()` / `ghAPIPaginated()`
/// response in `GitHubTransportShim` via a direct `await` (not fire-and-forget)
/// so that task cancellation propagates correctly and cancelled/timed-out
/// fetches do not increment the counter.
///
/// No persistence — the counter resets on app launch by design.
/// Memory is bounded: `purge()` evicts entries older than 3,600 s, and
/// `record()` trims to `hourlyLimit` entries via a suffix slice.
public actor APICallCounter: APICallCounterProtocol {
    /// Shared instance wired at module level.
    public static let shared = APICallCounter()

    /// GitHub authenticated REST rate limit per rolling hour.
    public static let hourlyLimit = 5_000

    /// Rolling buffer of call timestamps, always in ascending order.
    ///
    /// NB: monotonicity is assumed — timestamps are always appended as
    /// `Date()` which is generally monotonically increasing. Clock skew on
    /// system sleep/wake could yield duplicate or slightly regressed values;
    /// `purge()` and the trim are both tolerant of this in practice.
    private var timestamps: [Date] = []

    /// Creates a new `APICallCounter` instance.
    public init() {
        // Default property initializers fully define state.
    }

    // MARK: - Protocol

    /// Records one GitHub REST API call.
    ///
    /// Purges stale entries first (O(k) front-slice), appends the current
    /// timestamp, then caps the buffer at `hourlyLimit` via a suffix slice
    /// (avoids the O(n) element-shift cost of `removeFirst(n)`).
    public func record() {
        purge()
        timestamps.append(Date())
        if timestamps.count > Self.hourlyLimit {
            timestamps = Array(timestamps.suffix(Self.hourlyLimit))
        }
    }

    /// Returns `count` and `limit` in a single actor hop (P10).
    public func snapshot() -> APICallCounterSnapshot {
        purge()
        return APICallCounterSnapshot(count: timestamps.count, limit: Self.hourlyLimit)
    }

    // MARK: - Private

    /// Evicts timestamps older than the rolling 60-minute window.
    ///
    /// Because timestamps are always appended in ascending order, stale
    /// entries are always at the front. Uses `firstIndex(where:)` +
    /// `removeFirst(_:)` for an O(k) front-slice rather than a full O(n)
    /// `removeAll(where:)` sweep.
    private func purge() {
        let cutoff = Date().addingTimeInterval(-3_600)
        // NB: monotonicity assumed — see timestamps property comment.
        if let idx = timestamps.firstIndex(where: { $0 >= cutoff }) {
            if idx > 0 { timestamps.removeFirst(idx) }
        } else {
            timestamps.removeAll()
        }
    }
}

// MARK: - Module-level accessor

/// The module-wide `APICallCounter` instance shared by `GitHubTransportShim`.
public let apiCallCounter = APICallCounter.shared

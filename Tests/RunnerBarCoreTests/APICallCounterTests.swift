// APICallCounterTests.swift
// RunnerBarCoreTests
//
// Unit tests for APICallCounter and APICallCounterSnapshot.
//
// Structure mirrors GitHubRateLimitActorTests.swift: @Suite / @Test / #expect,
// no shared mutable state, each test creates its own actor instance.
//
// The key invariants tested:
//   1. Fresh actor starts at zero.
//   2. record() increments count within the rolling window.
//   3. fraction is always clamped to [0, 1].
//   4. snapshot() is atomic — consistent count + limit in one hop (P10).
//   5. APICallCounterSnapshot is Equatable and Sendable.
//   6. snapshot() returns zero after all timestamps expire (idle-gap regression).
//   7. ghAPI() does NOT increment the counter when the transport returns nil.
import Foundation
import Testing
@testable import RunnerBarCore

@Suite("APICallCounter")
struct APICallCounterTests {

    // MARK: - Defaults

    @Test("fresh actor starts at count zero")
    func freshActorStartsAtZero() async {
        let counter = APICallCounter()
        let snap = await counter.snapshot()
        #expect(snap.count == 0)
        #expect(snap.limit == APICallCounter.hourlyLimit)
    }

    @Test("fresh actor fraction is zero")
    func freshActorFractionIsZero() async {
        let counter = APICallCounter()
        let snap = await counter.snapshot()
        #expect(snap.fraction == 0.0)
    }

    // MARK: - record()

    @Test("record() increments count by one per call")
    func recordIncrementsCount() async {
        let counter = APICallCounter()
        await counter.record()
        await counter.record()
        await counter.record()
        let snap = await counter.snapshot()
        #expect(snap.count == 3)
    }

    @Test("record() from concurrent tasks all land in the count")
    func recordConcurrentTasks() async {
        let counter = APICallCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await counter.record() }
            }
        }
        let snap = await counter.snapshot()
        #expect(snap.count == 20)
    }

    // MARK: - fraction clamping

    @Test("fraction returns 0.0 when limit is zero to prevent NaN propagation")
    func fractionWithZeroLimitIsZero() {
        let snap = APICallCounterSnapshot(count: 42, limit: 0)
        #expect(snap.fraction == 0.0)
    }

    @Test("fraction is clamped to 1.0 when count exceeds limit")
    func fractionClampedToOne() {
        let snap = APICallCounterSnapshot(count: 9_999, limit: APICallCounter.hourlyLimit)
        #expect(snap.fraction == 1.0)
    }

    @Test("fraction is clamped to 0.0 when count is negative")
    func fractionClampedToZeroForNegativeCount() {
        let snap = APICallCounterSnapshot(count: -1, limit: APICallCounter.hourlyLimit)
        #expect(snap.fraction == 0.0)
    }

    @Test("fraction is exactly 0.5 at half the limit")
    func fractionAtHalf() {
        let snap = APICallCounterSnapshot(count: APICallCounter.hourlyLimit / 2, limit: APICallCounter.hourlyLimit)
        #expect(snap.fraction == 0.5)
    }

    @Test("fraction stays within [0, 1] for any count")
    func fractionBounded() {
        for count in [0, 1, 2_500, 5_000, 7_500, 10_000] {
            let snap = APICallCounterSnapshot(count: count, limit: APICallCounter.hourlyLimit)
            #expect(snap.fraction >= 0.0)
            #expect(snap.fraction <= 1.0)
        }
    }

    // MARK: - snapshot atomicity (P10)

    @Test("snapshot returns consistent count + limit in a single hop")
    func snapshotIsConsistent() async {
        let counter = APICallCounter()
        await counter.record()
        let s1 = await counter.snapshot()
        let s2 = await counter.snapshot()
        #expect(s1 == s2)
    }

    @Test("snapshot limit always equals hourlyLimit constant")
    func snapshotLimitMatchesConstant() async {
        let counter = APICallCounter()
        let snap = await counter.snapshot()
        #expect(snap.limit == APICallCounter.hourlyLimit)
    }

    // MARK: - Idle-gap regression (snapshot over-count)

    /// Regression test for the idle-gap over-count bug.
    ///
    /// **Scenario:** The actor records calls, then sits idle for over an hour.
    /// A subsequent `snapshot()` — with no intervening `record()` — must
    /// return zero, not the stale count from before the idle period.
    ///
    /// **How it works without real time travel:**
    /// `APICallCounter` has a test-only `seed(timestamps:)` extension in
    /// `Tests/RunnerBarCoreTests/APICallCounter+TestSeam.swift` that allows
    /// injecting pre-aged timestamps directly into the actor’s rolling buffer.
    @Test("snapshot() returns zero after all timestamps expire without a record() call")
    func snapshotPurgesIdleStaleEntries() async {
        let counter = APICallCounter()
        let stale = Date().addingTimeInterval(-5_400)
        await counter.seed(timestamps: [stale, stale])
        let snap = await counter.snapshot()
        #expect(snap.count == 0, "snapshot() must purge stale entries even without a prior record() call")
    }

    // MARK: - Transport nil-guard (shared actor pollution regression)

    /// Asserts that `ghAPI()` does **not** increment the counter when the
    /// configured transport returns `nil`.
    ///
    /// This guards against the `apiCallCounter.shared` pollution risk: if the
    /// `if result != nil` guard were ever removed, any test that exercises a
    /// nil-returning stub would permanently inflate the shared actor’s count
    /// for the rest of the test run.
    ///
    /// Uses `APICallCounter.shared.reset()` (test seam) to isolate from other
    /// tests that may have already incremented the shared instance.
    @Test("ghAPI() does not increment counter when transport returns nil")
    func ghAPISkipsCounterOnNilResult() async {
        await apiCallCounter.reset()
        configureGHAPI { _ in nil }
        _ = await ghAPI("https://api.github.com/test")
        await Task.yield()
        let snap = await apiCallCounter.snapshot()
        #expect(snap.count == 0, "counter must not increment when transport returns nil")
        configureGHAPI { _ in nil }
    }

    // MARK: - APICallCounterSnapshot struct

    @Test("APICallCounterSnapshot is Equatable")
    func snapshotEquatable() {
        let a = APICallCounterSnapshot(count: 42, limit: 5_000)
        let b = APICallCounterSnapshot(count: 42, limit: 5_000)
        let c = APICallCounterSnapshot(count: 99, limit: 5_000)
        #expect(a == b)
        #expect(a != c)
    }

    /// Compile-time conformance check for `APICallCounterSnapshot.Sendable`.
    ///
    /// Transfers a live snapshot across a `Task.detached` boundary to verify
    /// that the compiler accepts the value as `Sendable`. This test cannot fail
    /// at runtime for a value-type struct — it is a static conformance check,
    /// not a behavioural assertion. If `APICallCounterSnapshot` were ever changed
    /// to a `class`, this test would begin to carry runtime meaning.
    @Test("APICallCounterSnapshot is Sendable across task boundary")
    func snapshotSendable() async {
        let counter = APICallCounter()
        await counter.record()
        await counter.record()
        let snap = await counter.snapshot()
        let transferred = await Task.detached { snap }.value
        #expect(transferred.count == snap.count)
        #expect(transferred.limit == snap.limit)
    }
}

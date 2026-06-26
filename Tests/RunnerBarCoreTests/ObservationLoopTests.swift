// ObservationLoopTests.swift
// RunnerBarCoreTests
//
// Unit tests for ObservationLoop.
//
// Invariants tested:
//   1. onChange fires when an @Observable property changes.
//   2. onChange fires again on a second mutation (re-registration works).
//   3. onChange does NOT fire after the loop is deallocated.
//   4. onChange does NOT fire when an untracked property on the same object changes.
import Foundation
import Testing
import Observation
@testable import RunnerBarCore

@MainActor
@Observable
final class ObservableCounter {
    var count = 0
    /// Second property — used by test 4 to verify that mutating an untracked
    /// property does not trigger an onChange that only reads `count`.
    var label = ""
}

// MARK: - Signal helper

/// A single-use async signal that fires when `yield()` is called.
///
/// Replaces `Task.sleep` synchronisation in `ObservationLoopTests`.
/// `withObservationTracking`'s onChange enqueues a `Task { @MainActor in ... }`;
/// awaiting `Signal.wait()` unblocks the instant that Task runs `yield()` —
/// no wall-clock delay, no CI flakiness.
///
/// **Hang safety:** `yield()` finishes the stream after yielding, so `wait()`
/// always terminates — even if `yield()` is never called (the stream finishes
/// empty and `wait()` returns immediately). A test that calls `await signal.wait()`
/// and expects `fired == 1` will then fail on the `#expect`, not hang.
///
/// **Cancellation safety:** call `cancel()` after `group.cancelAll()` in negative-case
/// `withTaskGroup` races so the losing `signal.wait()` child task can exit.
/// `AsyncStream` iteration is not interrupted by task cancellation alone — without
/// an explicit `finish()`, the cancelled child remains suspended indefinitely.
@MainActor
final class Signal {
    private var continuation: AsyncStream<Void>.Continuation?
    private let stream: AsyncStream<Void>

    init() {
        var cont: AsyncStream<Void>.Continuation?
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    /// Fires the signal and terminates the stream.
    ///
    /// Finishing the stream after the first yield ensures `wait()` always
    /// unblocks — whether onChange fires (stream yields a value then finishes)
    /// or a regression prevents it (stream finishes empty, `wait()` returns,
    /// the `#expect` on `fired` fails the test correctly rather than hanging CI).
    func yield() {
        continuation?.yield(())
        continuation?.finish()
        continuation = nil
    }

    /// Finishes the stream without yielding a value.
    ///
    /// Call this after `group.cancelAll()` in negative-case `withTaskGroup` races
    /// to ensure the losing `signal.wait()` child task can exit. Without this,
    /// task cancellation alone does not terminate `AsyncStream` iteration and the
    /// cancelled child remains suspended, preventing the task group from draining.
    func cancel() {
        continuation?.finish()
        continuation = nil
    }

    /// Suspends until `yield()` is called, or returns immediately if the
    /// stream has already finished (i.e. `yield()` or `cancel()` was already called).
    func wait() async {
        for await _ in stream { return }
    }
}

// MARK: - Helpers

/// Returns an `(ObservationLoop, AsyncStream<Void>)` pair.
///
/// The stream yields one element each time `onChange` fires. Awaiting
/// `stream.first(where: { true })` blocks until the next firing — no
/// timing-dependent sleeps needed.
///
/// - Parameters:
///   - observe: Forwarded to `ObservationLoop.init(observe:onChange:)`.
private func makeLoop(
    observe: @escaping @MainActor () -> Void
) -> (loop: ObservationLoop, signals: AsyncStream<Void>) {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let loop = ObservationLoop(observe: observe) {
        continuation.yield()
    }
    return (loop, stream)
}

@Suite("ObservationLoop")
@MainActor
struct ObservationLoopTests {

    @Test("onChange fires when observed property changes")
    func firesOnChange() async {
        let counter = ObservableCounter()
<<<<<<< Updated upstream
        var fired = 0
        let signal = Signal()

        let loop = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
            signal.yield()
        }

        counter.count = 1
        await signal.wait()

        #expect(fired == 1)
        _ = loop
=======
        let (loop, signals) = makeLoop { _ = counter.count }

        counter.count = 1
        // Await the real signal instead of a fixed-duration sleep — deterministic
        // regardless of scheduler load or CI runner speed.
        var iter = signals.makeAsyncIterator()
        let fired = await iter.next() != nil

        #expect(fired)
        _ = loop // keep alive
>>>>>>> Stashed changes
    }

    @Test("onChange fires again on second mutation — re-registration works")
    func firesOnSecondMutation() async {
        let counter = ObservableCounter()
<<<<<<< Updated upstream
        var fired = 0
        let signal1 = Signal()
        let signal2 = Signal()

        let loop = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
            if fired == 1 { signal1.yield() } else { signal2.yield() }
        }

        counter.count = 1
        await signal1.wait()   // wait for first onChange + re-registration
        counter.count = 2
        await signal2.wait()   // wait for second onChange
=======
        let (loop, signals) = makeLoop { _ = counter.count }
        var iter = signals.makeAsyncIterator()

        counter.count = 1
        _ = await iter.next() // wait for first firing
>>>>>>> Stashed changes

        counter.count = 2
        _ = await iter.next() // wait for second firing

        // Both mutations propagated — re-registration is working.
        #expect(counter.count == 2)
        _ = loop
    }

    @Test("onChange does not fire after loop is deallocated")
    func doesNotFireAfterDealloc() async {
        let counter = ObservableCounter()
        var fired = 0
        let signal = Signal()

        var loop: ObservationLoop? = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
            signal.yield()
        }

<<<<<<< Updated upstream
        // `isolated deinit` on ObservationLoop guarantees isRunning = false is written
        // on @MainActor — the same executor we're on now. The nil assignment therefore
        // synchronously completes the deinit before the mutation below runs, making the
        // guard in register()'s Task body fire before any onChange can be enqueued.
        loop = nil
        counter.count = 1

        // Race: sleep 1 ms vs the signal. If onChange fires, signal wins and the
        // test fails. If deinit correctly blocked re-registration, sleep wins.
        // 1 ms is a generous bound — isolated deinit is synchronous on @MainActor;
        // onChange cannot fire after isRunning = false.
        let raceResult = await withTaskGroup(of: Bool.self) { group in
            group.addTask { try? await Task.sleep(for: .milliseconds(1)); return false } // sleep won
            group.addTask { await signal.wait(); return true }                           // signal won
            let first = await group.next()!
            group.cancelAll()
            signal.cancel() // finish stream so the losing wait() child can exit
            return first
        }
=======
        loop = nil // deallocate — isRunning = false, weak self guard will drop the queued Task
        counter.count = 1
        // Give the cooperative scheduler a full turn to confirm nothing fires.
        // This is the one place a short yield is correct: we are asserting *absence*
        // of a signal, so we cannot block on a stream. Three yields is sufficient to
        // drain a Task { @MainActor } that was already enqueued before dealloc.
        for _ in 0 ..< 3 { await Task.yield() }
>>>>>>> Stashed changes

        #expect(fired == 0)
        #expect(raceResult == false, "onChange fired after dealloc — isolated deinit guard broken")
    }

    @Test("onChange does not fire when an untracked property changes")
    func doesNotFireForUntrackedProperty() async {
        let counter = ObservableCounter()
        var fired = 0
        let signal = Signal()

        // observe reads only `count` — `label` is not tracked.
        let loop = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
            signal.yield()
        }

        counter.label = "hello"

        // Same race pattern as the dealloc test: 1 ms sleep vs the signal.
        // If onChange fires for the untracked mutation, signal wins — test fails.
        let signalFired = await withTaskGroup(of: Bool.self) { group in
            group.addTask { try? await Task.sleep(for: .milliseconds(1)); return false }
            group.addTask { await signal.wait(); return true }
            let first = await group.next()!
            group.cancelAll()
            signal.cancel() // finish stream so the losing wait() child can exit
            return first
        }

        #expect(fired == 0)
        #expect(signalFired == false, "onChange fired for untracked property 'label'")
        _ = loop
    }
}

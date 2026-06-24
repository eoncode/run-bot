// ObservationLoopTests.swift
// RunnerBarCoreTests
//
// Unit tests for ObservationLoop.
//
// Invariants tested:
//   1. onChange fires when an @Observable property changes.
//   2. onChange fires again on a second mutation (re-registration works).
//   3. onChange does NOT fire after the loop is deallocated.
import Foundation
import Testing
import Observation
@testable import RunnerBarCore

@Observable
final class ObservableCounter {
    var count = 0
}

@Suite("ObservationLoop")
@MainActor
struct ObservationLoopTests {

    @Test("onChange fires when observed property changes")
    func firesOnChange() async throws {
        let counter = ObservableCounter()
        var fired = 0

        let loop = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
        }

        counter.count = 1
        // Yield to allow the MainActor onChange handler to execute.
        await Task.yield()

        #expect(fired == 1)
        _ = loop // keep alive
    }

    @Test("onChange fires again on second mutation — re-registration works")
    func firesOnSecondMutation() async throws {
        let counter = ObservableCounter()
        var fired = 0

        let loop = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
        }

        counter.count = 1
        await Task.yield()
        counter.count = 2
        await Task.yield()

        #expect(fired == 2)
        _ = loop
    }

    @Test("onChange does not fire after loop is deallocated")
    func doesNotFireAfterDealloc() async throws {
        let counter = ObservableCounter()
        var fired = 0

        var loop: ObservationLoop? = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
        }

        loop = nil // deallocate
        counter.count = 1
        await Task.yield()

        #expect(fired == 0)
    }
}

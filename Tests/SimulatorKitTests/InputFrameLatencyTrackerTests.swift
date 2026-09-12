import XCTest
@testable import SimulatorKit

final class InputFrameLatencyTrackerTests: XCTestCase {
    func testAnIdleScreenDoesNotInventAZeroLatencySample() {
        let tracker = InputFrameLatencyTracker()
        tracker.recordInput(at: 10)
        let pending = tracker.statistics(at: 10.5)
        XCTAssertEqual(pending.sampleCount, 0)
        XCTAssertEqual(pending.pendingInputCount, 1)
        XCTAssertNil(pending.medianMilliseconds)
        XCTAssertNil(pending.p95Milliseconds)
        XCTAssertNil(pending.latestMilliseconds)
        let expired = tracker.statistics(at: 12.001)
        XCTAssertEqual(expired.pendingInputCount, 0)
        XCTAssertEqual(expired.sampleCount, 0)
    }

    func testBufferedPreInputFrameCannotSatisfyNewerInput() throws {
        let tracker = InputFrameLatencyTracker()
        tracker.recordInput(at: 10)
        tracker.recordInput(at: 10.02)
        tracker.submitted(frameReceivedAt: 10.01, at: 10.03)
        let first = tracker.statistics(at: 10.03)
        XCTAssertEqual(first.sampleCount, 1)
        XCTAssertEqual(first.pendingInputCount, 1)
        XCTAssertEqual(try XCTUnwrap(first.latestMilliseconds), 30, accuracy: 0.000_001)
        tracker.submitted(frameReceivedAt: 10.025, at: 10.05)
        let second = tracker.statistics(at: 10.05)
        XCTAssertEqual(second.sampleCount, 2)
        XCTAssertEqual(second.pendingInputCount, 0)
        XCTAssertEqual(try XCTUnwrap(second.medianMilliseconds), 30, accuracy: 0.000_001)
    }

    func testFirstEligibleFrameConsumesEveryEligibleInputExactlyOnce() throws {
        let tracker = InputFrameLatencyTracker()
        tracker.recordInput(at: 1)
        tracker.recordInput(at: 1.01)
        tracker.recordInput(at: 1.02)
        tracker.submitted(frameReceivedAt: 1.04, at: 1.1)
        let first = tracker.statistics(at: 1.1)
        XCTAssertEqual(first.sampleCount, 3)
        XCTAssertEqual(first.pendingInputCount, 0)
        XCTAssertEqual(try XCTUnwrap(first.medianMilliseconds), 90, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(first.p95Milliseconds), 100, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(first.latestMilliseconds), 80, accuracy: 0.000_001)
        tracker.submitted(frameReceivedAt: 1.04, at: 1.2) // repaint
        tracker.submitted(frameReceivedAt: 1.2, at: 1.21) // unrelated later frame
        XCTAssertEqual(tracker.statistics(at: 1.21).sampleCount, 3)
    }

    func testEqualReceiptTimeAndStaleOrRepaintedFramesAreIgnored() {
        let tracker = InputFrameLatencyTracker()
        tracker.recordInput(at: 5)
        tracker.submitted(frameReceivedAt: 5, at: 5.01)
        XCTAssertEqual(tracker.statistics(at: 5.01).sampleCount, 0)
        tracker.submitted(frameReceivedAt: 4.9, at: 5.1)
        tracker.submitted(frameReceivedAt: 5, at: 5.2)
        XCTAssertEqual(tracker.statistics(at: 5.2).pendingInputCount, 1)
        tracker.submitted(frameReceivedAt: 5.21, at: 5.22)
        XCTAssertEqual(tracker.statistics(at: 5.22).sampleCount, 1)
    }

    func testInvalidClocksCannotExpireOrContaminateMeasurements() {
        let tracker = InputFrameLatencyTracker()
        tracker.recordInput(at: 100)
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            tracker.recordInput(at: invalid)
            tracker.submitted(frameReceivedAt: invalid, at: 100.1)
            tracker.submitted(frameReceivedAt: 100.01, at: invalid)
            XCTAssertEqual(tracker.statistics(at: invalid).pendingInputCount, 1)
        }
        tracker.submitted(frameReceivedAt: 100.2, at: 100.1) // submission before receipt
        XCTAssertEqual(tracker.statistics(at: 100.1).sampleCount, 0)
        tracker.submitted(frameReceivedAt: 100.2, at: 100.3)
        XCTAssertEqual(tracker.statistics(at: 100.3).sampleCount, 1)
    }

    func testTwoSecondExpiryBoundaryAndClockRollback() throws {
        let tracker = InputFrameLatencyTracker()
        tracker.recordInput(at: 10)
        tracker.recordInput(at: 10.001)
        tracker.submitted(frameReceivedAt: 11.9, at: 12.001)
        let result = tracker.statistics(at: 12.001)
        XCTAssertEqual(result.sampleCount, 1, "Age strictly above two seconds is expired")
        XCTAssertEqual(try XCTUnwrap(result.latestMilliseconds), 2_000, accuracy: 0.000_001)
        tracker.recordInput(at: 9) // stale input after clock advanced
        XCTAssertEqual(tracker.statistics(at: 9).pendingInputCount, 0)
        XCTAssertEqual(tracker.statistics(at: 9).sampleCount, 1)
    }

    func testPendingAndSampleWindowsEvictOldestValues() throws {
        let tracker = InputFrameLatencyTracker()
        for index in 0..<40 { tracker.recordInput(at: Double(index) / 1_000) }
        XCTAssertEqual(tracker.statistics(at: 0.04).pendingInputCount, 32)
        tracker.submitted(frameReceivedAt: 0.05, at: 0.1)
        let bounded = tracker.statistics(at: 0.1)
        XCTAssertEqual(bounded.sampleCount, 32)
        XCTAssertEqual(try XCTUnwrap(bounded.p95Milliseconds), 91, accuracy: 0.000_001)

        tracker.reset()
        for index in 0..<130 {
            let input = Double(index) * 3
            tracker.recordInput(at: input)
            tracker.submitted(frameReceivedAt: input + 0.001, at: input + Double(index + 1) / 1_000)
        }
        let recent = tracker.statistics(at: 390)
        XCTAssertEqual(recent.sampleCount, 120)
        XCTAssertEqual(try XCTUnwrap(recent.medianMilliseconds), 70.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(recent.p95Milliseconds), 124, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(recent.latestMilliseconds), 130, accuracy: 0.000_001)
    }

    func testReconnectDropsPendingAndResetAlsoClearsHistory() {
        let tracker = InputFrameLatencyTracker()
        tracker.recordInput(at: 20)
        tracker.submitted(frameReceivedAt: 20.01, at: 20.02)
        tracker.recordInput(at: 20.03)
        tracker.clearPending()
        tracker.submitted(frameReceivedAt: 20.04, at: 20.05)
        XCTAssertEqual(tracker.statistics(at: 20.05).sampleCount, 1)
        XCTAssertEqual(tracker.statistics(at: 20.05).pendingInputCount, 0)
        tracker.reset()
        XCTAssertEqual(tracker.statistics(at: 0).sampleCount, 0)
        tracker.recordInput(at: 1)
        tracker.submitted(frameReceivedAt: 1.01, at: 1.02)
        XCTAssertEqual(tracker.statistics(at: 1.02).sampleCount, 1, "Reset also clears earlier clock/frame watermarks")
    }

    func testConcurrentInputSubmissionSnapshotsAndResetsRemainBounded() {
        let tracker = InputFrameLatencyTracker()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<200 {
                let at = Double(index) / 100 + Double(worker) / 10_000
                tracker.recordInput(at: at)
                tracker.submitted(frameReceivedAt: at + 0.001, at: at + 0.002)
                if index.isMultiple(of: 37) { tracker.clearPending() }
                if worker == 0, index.isMultiple(of: 79) { tracker.reset() }
                let result = tracker.statistics(at: at + 0.003)
                XCTAssertLessThanOrEqual(result.pendingInputCount, 32)
                XCTAssertLessThanOrEqual(result.sampleCount, 120)
                if let median = result.medianMilliseconds {
                    XCTAssertTrue(median.isFinite)
                    XCTAssertGreaterThanOrEqual(median, 0)
                    XCTAssertLessThanOrEqual(median, 2_000)
                }
            }
        }
        tracker.reset()
        XCTAssertEqual(tracker.statistics(at: 0).sampleCount, 0)
    }
}

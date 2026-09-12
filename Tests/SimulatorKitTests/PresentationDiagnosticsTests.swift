import XCTest
@testable import SimulatorKit

final class PresentationDiagnosticsTests: XCTestCase {
    func testOutcomesSeparateTimerDelayLayerBackpressureAndConstructionErrors() throws {
        let metrics = PresentationDiagnostics()
        metrics.recordTick(at: 10, completedAt: 10.002, outcome: .noFrame, layerStatus: .unknown)
        metrics.recordTick(at: 10.016, completedAt: 10.017, outcome: .notReady, layerStatus: .rendering)
        metrics.recordTick(at: 10.032, completedAt: 10.042, outcome: .enqueued, layerStatus: .failed,
                           flushCount: 2, layerError: "decoder display failure")
        metrics.recordTick(at: 10.132, completedAt: 10.133, outcome: .formatError(-12710), layerStatus: .rendering)
        metrics.recordTick(at: 10.148, completedAt: 10.149, outcome: .sampleError(-12731), layerStatus: .rendering)

        let value = metrics.snapshot(at: 11)
        XCTAssertEqual(value.ticks, 5)
        XCTAssertEqual(value.noFrame, 1)
        XCTAssertEqual(value.notReady, 1)
        XCTAssertEqual(value.enqueued, 1)
        XCTAssertEqual(value.formatErrors, 1)
        XCTAssertEqual(value.sampleErrors, 1)
        XCTAssertEqual(value.lastFormatError, -12710)
        XCTAssertEqual(value.lastSampleError, -12731)
        XCTAssertEqual(value.flushes, 2, "Count both failure recovery and dimension-change flushes")
        XCTAssertEqual(value.failedLayerTicks, 1)
        XCTAssertEqual(value.lastLayerStatus, .rendering)
        XCTAssertEqual(value.lastLayerError, "decoder display failure", "Healthy ticks retain the last failure detail")
        XCTAssertEqual(value.maximumTickGapMilliseconds, 100, accuracy: 0.0001)
        XCTAssertEqual(value.delayedTickGaps, 1)
        XCTAssertEqual(value.maximumWorkMilliseconds, 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(value.elapsedSeconds), 1, accuracy: 0.0001)
    }

    func testExplicitStreamClockResetAndInvalidObservationsDoNotPolluteMeasurements() throws {
        let metrics = PresentationDiagnostics()
        metrics.reset(at: 10)
        metrics.recordTick(at: 10.25, completedAt: 10.251, outcome: .enqueued, layerStatus: .rendering)
        let before = metrics.snapshot(at: 70)
        XCTAssertEqual(before.startedAtUptime, 10)
        XCTAssertEqual(before.sampledAtUptime, 70)
        XCTAssertEqual(try XCTUnwrap(before.elapsedSeconds), 60, accuracy: 0.0001)

        for (start, end) in [(Double.nan, 12.0), (-1.0, 12.0), (10.0, 12.0),
                             (12.0, 11.0), (12.0, Double.infinity), (12.0, Double.greatestFiniteMagnitude)] {
            metrics.recordTick(at: start, completedAt: end, outcome: .formatError(-1), layerStatus: .failed, flushCount: 1)
        }
        XCTAssertEqual(metrics.snapshot(at: 70), before)
        XCTAssertNil(metrics.snapshot(at: 9).sampledAtUptime)

        metrics.reset(at: 500)
        metrics.recordTick(at: 500.016, completedAt: 500.017, outcome: .noFrame, layerStatus: .unknown)
        let after = metrics.snapshot(at: 501)
        XCTAssertEqual(after.ticks, 1)
        XCTAssertEqual(after.maximumTickGapMilliseconds, 0, "Reconnect downtime is outside the new stream")
        XCTAssertEqual(try XCTUnwrap(after.elapsedSeconds), 1, accuracy: 0.0001)
        XCTAssertEqual(after.enqueued, 0)
        metrics.reset()
        XCTAssertEqual(metrics.snapshot(at: 600), PresentationDiagnostics.Snapshot())
    }

    func testLastErrorRetainsOnlyBoundedValidUTF8() {
        let metrics = PresentationDiagnostics()
        let source = "x" + String(repeating: "🙂", count: 400)
        metrics.recordTick(at: 0, completedAt: 0, outcome: .notReady, layerStatus: .failed, layerError: source)
        let error = metrics.snapshot(at: 0).lastLayerError
        XCTAssertEqual(error, "x" + String(repeating: "🙂", count: 127))
        XCTAssertLessThanOrEqual(error?.utf8.count ?? 0, PresentationDiagnostics.maximumErrorUTF8Bytes)
        XCTAssertFalse(error?.contains("\u{FFFD}") ?? true)
        metrics.reset()
        XCTAssertNil(metrics.snapshot.lastLayerError)
    }

    func testConcurrentRecordingKeepsExactCountsWithFixedSnapshotState() {
        let metrics = PresentationDiagnostics()
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            metrics.recordTick(at: 1, completedAt: 1.001,
                               outcome: index.isMultiple(of: 2) ? .noFrame : .enqueued, layerStatus: .rendering)
            _ = metrics.snapshot(at: 2)
        }
        let value = metrics.snapshot(at: 2)
        XCTAssertEqual(value.ticks, 1_000)
        XCTAssertEqual(value.noFrame, 500)
        XCTAssertEqual(value.enqueued, 500)
        XCTAssertEqual(value.delayedTickGaps, 0)
        XCTAssertEqual(value.maximumTickGapMilliseconds, 0)
    }
}

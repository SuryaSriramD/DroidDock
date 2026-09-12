import XCTest
import CoreVideo
import CoreMedia
import SimulatorKit
@testable import AndroidSimulator

final class FrameStorePresentationTests: XCTestCase {
    func testReconnectBaselinesFrameAndSurfaceCountsWithoutResettingSessionCounters() throws {
        let store = FrameStore()
        let first = UUID(), second = UUID()
        let frame = try makeFrame()
        store.beginStream(first)
        store.put(frame, stream: first)
        store.put(frame, stream: first)
        store.submitted(try XCTUnwrap(store.take()))
        recordTick(store, outcome: .enqueued)
        let before = store.surfaceMetrics
        XCTAssertEqual(before.streamID, first)
        XCTAssertEqual(before.decodedFrames, 2)
        XCTAssertEqual(before.submittedFrames, 1)
        XCTAssertEqual(before.counters.enqueued, 1)
        XCTAssertNotNil(before.counters.startedAtUptime)
        XCTAssertNotNil(before.counters.sampledAtUptime)

        store.beginStream(second)
        store.put(frame, stream: first) // A retired callback cannot enter the new measurement.
        let fresh = store.surfaceMetrics
        XCTAssertEqual(fresh.streamID, second)
        XCTAssertEqual(fresh.decodedFrames, 0)
        XCTAssertEqual(fresh.submittedFrames, 0)
        XCTAssertEqual(fresh.counters.ticks, 0)
        XCTAssertEqual(store.stats().0, 2, "Existing session-level FPS counters retain their scope")
        XCTAssertEqual(store.presentationStats().count, 1)
        store.put(frame, stream: second)
        store.submitted(try XCTUnwrap(store.take()))
        recordTick(store, outcome: .enqueued)
        let after = store.surfaceMetrics
        XCTAssertEqual(after.decodedFrames, 1)
        XCTAssertEqual(after.submittedFrames, 1)
        XCTAssertEqual(after.counters.enqueued, 1)
    }

    func testInactiveSurfaceTicksAreIgnoredAndNewSessionResetsAllScopes() throws {
        let store = FrameStore()
        recordTick(store, outcome: .noFrame)
        XCTAssertEqual(store.surfaceMetrics.counters.ticks, 0)
        let stream = UUID()
        store.beginStream(stream)
        store.put(try makeFrame(), stream: stream)
        recordTick(store, outcome: .notReady)
        store.clear()
        recordTick(store, outcome: .noFrame)
        XCTAssertEqual(store.surfaceMetrics.counters.ticks, 1)
        XCTAssertEqual(store.surfaceMetrics.counters.notReady, 1)
        store.reset()
        let reset = store.surfaceMetrics
        XCTAssertNil(reset.streamID)
        XCTAssertEqual(reset.decodedFrames, 0)
        XCTAssertEqual(reset.submittedFrames, 0)
        XCTAssertEqual(reset.counters, PresentationDiagnostics.Snapshot())
        XCTAssertEqual(store.stats().0, 0)
        XCTAssertEqual(store.presentationStats().count, 0)
    }

    private func recordTick(_ store: FrameStore, outcome: PresentationDiagnostics.Outcome) {
        let now = ProcessInfo.processInfo.systemUptime
        store.recordPresentationTick(at: now, completedAt: now, outcome: outcome,
                                     layerStatus: .rendering, flushCount: 0, layerError: nil)
    }

    private func makeFrame() throws -> DecodedFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let now = ProcessInfo.processInfo.systemUptime
        return DecodedFrame(pixelBuffer: try XCTUnwrap(buffer), presentationTime: .zero, receivedAt: now, decodedAt: now)
    }
}

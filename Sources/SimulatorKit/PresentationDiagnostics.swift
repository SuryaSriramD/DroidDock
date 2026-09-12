import Foundation

/// Fixed-size counters for the host presentation callback. These distinguish
/// delayed callbacks, display-layer backpressure, and a quiet decoded stream;
/// they do not measure physical presentation or Android response latency.
public final class PresentationDiagnostics: @unchecked Sendable {
    public static let delayedTickThresholdMilliseconds = 50.0
    public static let maximumErrorUTF8Bytes = 512

    public enum LayerStatus: String, Sendable, Equatable {
        case unknown, rendering, failed, unrecognized
    }

    /// Each timer callback has exactly one terminal outcome. Layer failures and
    /// flushes are independent: a callback may recover and enqueue after a flush.
    public enum Outcome: Sendable {
        case notReady, noFrame, enqueued
        case formatError(Int32), sampleError(Int32)
    }

    public struct Snapshot: Sendable, Equatable {
        public fileprivate(set) var startedAtUptime: TimeInterval?
        public fileprivate(set) var sampledAtUptime: TimeInterval?
        public fileprivate(set) var ticks: UInt64 = 0
        public fileprivate(set) var maximumTickGapMilliseconds = 0.0
        public fileprivate(set) var delayedTickGaps: UInt64 = 0
        public fileprivate(set) var maximumWorkMilliseconds = 0.0
        public fileprivate(set) var notReady: UInt64 = 0
        public fileprivate(set) var noFrame: UInt64 = 0
        public fileprivate(set) var enqueued: UInt64 = 0
        public fileprivate(set) var flushes: UInt64 = 0
        public fileprivate(set) var failedLayerTicks: UInt64 = 0
        public fileprivate(set) var formatErrors: UInt64 = 0
        public fileprivate(set) var sampleErrors: UInt64 = 0
        public fileprivate(set) var lastFormatError: Int32?
        public fileprivate(set) var lastSampleError: Int32?
        public fileprivate(set) var lastLayerStatus: LayerStatus = .unknown
        public fileprivate(set) var lastLayerError: String?

        public var elapsedSeconds: TimeInterval? {
            guard let startedAtUptime, let sampledAtUptime else { return nil }
            return sampledAtUptime - startedAtUptime
        }

        public init() {}
    }

    private let lock = NSLock()
    private var values = Snapshot()
    private var lastTickAt: TimeInterval?

    public init() {}

    public var snapshot: Snapshot { snapshot(at: ProcessInfo.processInfo.systemUptime) }

    public func snapshot(at timestamp: TimeInterval) -> Snapshot {
        lock.withLock {
            var result = values
            if let start = values.startedAtUptime, timestamp.isFinite, timestamp >= start {
                result.sampledAtUptime = timestamp
            }
            return result
        }
    }

    /// Timestamps are monotonic host uptime. Invalid or backward observations
    /// are ignored completely, so they cannot corrupt counts or timing maxima.
    public func recordTick(at startedAt: TimeInterval, completedAt: TimeInterval,
                           outcome: Outcome, layerStatus: LayerStatus,
                           flushCount: UInt64 = 0, layerError: String? = nil) {
        guard startedAt.isFinite, startedAt >= 0, completedAt.isFinite,
              completedAt >= startedAt else { return }
        let workMilliseconds = (completedAt - startedAt) * 1_000
        guard workMilliseconds.isFinite else { return }
        lock.withLock {
            guard lastTickAt.map({ startedAt >= $0 }) ?? true,
                  values.startedAtUptime.map({ startedAt >= $0 }) ?? true else { return }
            if let lastTickAt {
                let gap = (startedAt - lastTickAt) * 1_000
                guard gap.isFinite else { return }
                values.maximumTickGapMilliseconds = max(values.maximumTickGapMilliseconds, gap)
                if gap > Self.delayedTickThresholdMilliseconds { values.delayedTickGaps &+= 1 }
            }
            if values.startedAtUptime == nil { values.startedAtUptime = startedAt }
            lastTickAt = startedAt
            values.ticks &+= 1
            values.maximumWorkMilliseconds = max(values.maximumWorkMilliseconds, workMilliseconds)
            values.lastLayerStatus = layerStatus
            if layerStatus == .failed { values.failedLayerTicks &+= 1 }
            values.flushes &+= flushCount
            if let layerError { values.lastLayerError = Self.boundedError(layerError) }
            switch outcome {
            case .notReady: values.notReady &+= 1
            case .noFrame: values.noFrame &+= 1
            case .enqueued: values.enqueued &+= 1
            case .formatError(let code):
                values.formatErrors &+= 1; values.lastFormatError = code
            case .sampleError(let code):
                values.sampleErrors &+= 1; values.lastSampleError = code
            }
        }
    }

    /// Start a fresh measurement interval without retaining an earlier stream's
    /// last tick; reconnect downtime must not become a presentation-stall sample.
    public func reset(at timestamp: TimeInterval? = nil) {
        lock.withLock {
            values = Snapshot(); lastTickAt = nil
            if let timestamp, timestamp.isFinite, timestamp >= 0 { values.startedAtUptime = timestamp }
        }
    }

    private static func boundedError(_ text: String) -> String {
        var bytes = Array(text.utf8.prefix(maximumErrorUTF8Bytes))
        // Input is valid UTF-8, so only the final partial scalar can be invalid.
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }
}

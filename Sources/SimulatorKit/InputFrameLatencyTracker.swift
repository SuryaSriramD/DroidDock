import Foundation

/// A host-side input-dispatch → frame-submission timing proxy. Each input is
/// paired with the first submitted frame received strictly after that input.
/// This does not establish that Android responded to the input: an unrelated
/// animation can supply the frame. Submission also precedes physical display,
/// so these samples are neither causal guest-response nor display latency.
public final class InputFrameLatencyTracker: @unchecked Sendable {
    public struct Statistics: Sendable, Equatable {
        /// Number of samples in the bounded, most-recent 120-sample window.
        public let sampleCount: Int
        public let medianMilliseconds: Double?
        /// Nearest-rank 95th percentile of the retained samples.
        public let p95Milliseconds: Double?
        public let latestMilliseconds: Double?
        public let pendingInputCount: Int
    }

    public static let maximumPendingInputs = 32
    public static let maximumSamples = 120
    public static let maximumInputAge: TimeInterval = 2

    private let lock = NSLock()
    private var pending: [TimeInterval] = []
    private var samples: [Double] = []
    private var latestObservedAt: TimeInterval = 0
    private var latestFrameReceivedAt: TimeInterval?
    private var latestSubmissionAt: TimeInterval?

    public init() {}

    /// All timestamps must use the same monotonic host clock, in seconds.
    /// Invalid timestamps and inputs older than an already submitted frame's
    /// submission are ignored; their first subsequent frame cannot be recovered.
    public func recordInput(at timestamp: TimeInterval) {
        guard Self.valid(timestamp) else { return }
        lock.withLock {
            expire(at: timestamp)
            guard latestObservedAt - timestamp <= Self.maximumInputAge,
                  latestSubmissionAt.map({ timestamp >= $0 }) ?? true else { return }
            pending.append(timestamp)
            pending.sort()
            if pending.count > Self.maximumPendingInputs {
                pending.removeFirst(pending.count - Self.maximumPendingInputs)
            }
        }
    }

    /// Call when a decoded frame is actually submitted to the native surface.
    /// Repainting the same frame, out-of-order frames, pre-input frames, and
    /// timestamps preceding receipt cannot create samples. All eligible pending
    /// inputs share this first subsequent frame; each input is consumed once.
    public func submitted(frameReceivedAt: TimeInterval, at timestamp: TimeInterval) {
        guard Self.valid(frameReceivedAt), Self.valid(timestamp), timestamp >= frameReceivedAt else { return }
        lock.withLock {
            expire(at: timestamp)
            guard latestSubmissionAt.map({ timestamp >= $0 }) ?? true,
                  latestFrameReceivedAt.map({ frameReceivedAt > $0 }) ?? true else { return }
            latestSubmissionAt = timestamp
            latestFrameReceivedAt = frameReceivedAt
            var waiting: [TimeInterval] = []
            for input in pending {
                if frameReceivedAt > input {
                    let milliseconds = (timestamp - input) * 1_000
                    if milliseconds.isFinite, milliseconds >= 0,
                       milliseconds <= Self.maximumInputAge * 1_000 {
                        samples.append(milliseconds)
                    }
                } else { waiting.append(input) }
            }
            pending = waiting
            if samples.count > Self.maximumSamples {
                samples.removeFirst(samples.count - Self.maximumSamples)
            }
        }
    }

    /// Snapshot using the same uptime clock as DecodedFrame.receivedAt.
    public var statistics: Statistics { statistics(at: ProcessInfo.processInfo.systemUptime) }

    /// Explicit-clock snapshot, useful when the caller already sampled uptime.
    /// Reading also expires pending inputs; a clock moving backward cannot
    /// revive them. A nonfinite or negative timestamp leaves state unchanged.
    public func statistics(at timestamp: TimeInterval) -> Statistics {
        lock.withLock {
            if Self.valid(timestamp) { expire(at: timestamp) }
            let sorted = samples.sorted()
            let count = sorted.count
            let median: Double?
            if count == 0 { median = nil }
            else if count.isMultiple(of: 2) { median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2 }
            else { median = sorted[count / 2] }
            let percentile = count == 0 ? nil : sorted[Int(ceil(Double(count) * 0.95)) - 1]
            return Statistics(sampleCount: count, medianMilliseconds: median,
                              p95Milliseconds: percentile, latestMilliseconds: samples.last,
                              pendingInputCount: pending.count)
        }
    }

    /// A stream reconnect drops unmatched inputs but retains measured history.
    public func clearPending() { lock.withLock { pending.removeAll(keepingCapacity: true) } }

    /// Start a new measurement session, clearing pending inputs and samples.
    public func reset() {
        lock.withLock {
            pending.removeAll(keepingCapacity: true)
            samples.removeAll(keepingCapacity: true)
            latestObservedAt = 0
            latestFrameReceivedAt = nil
            latestSubmissionAt = nil
        }
    }

    private static func valid(_ timestamp: TimeInterval) -> Bool { timestamp.isFinite && timestamp >= 0 }

    /// Called only while holding lock. The high-water mark makes expiration
    /// stable even if concurrent callers deliver their observations out of order.
    private func expire(at timestamp: TimeInterval) {
        latestObservedAt = max(latestObservedAt, timestamp)
        pending.removeAll { latestObservedAt - $0 > Self.maximumInputAge }
    }
}

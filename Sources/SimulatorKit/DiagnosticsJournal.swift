import Foundation
import OSLog

/// Exportable application lifecycle events, separate from guest Logcat and
/// emulator stdout. Callers supply only deliberate diagnostic descriptions;
/// this utility never collects commands, environment variables or user input.
public final class SessionEventLog: @unchecked Sendable {
    public let url: URL
    public static let maximumFileBytes = 2 * 1_024 * 1_024
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.androidsimulator.session-events", qos: .utility)
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let logger = Logger(subsystem: "dev.androidsimulator.mac", category: "session")
    private var pending: [Event] = []
    private var pendingBytes = 0
    private var drainScheduled = false
    private var hasWriteFailure = false // Accessed only on queue.
    private var checkedExistingTail = false // Accessed only on queue.

    private struct Event: Encodable, Sendable {
        let schemaVersion = 1
        let timestamp: Date
        let sessionID: String
        let state: String
        let message: String
        var byteCount: Int { sessionID.utf8.count + state.utf8.count + message.utf8.count + 256 }
    }

    /// Use one journal instance per file. Existing complete events are retained
    /// across launches; oldest events are discarded when the file reaches 2 MB.
    public init(url: URL) throws {
        guard url.isFileURL, !url.hasDirectoryPath else {
            throw RuntimeError.invalidArgument("Session diagnostics require a file URL.")
        }
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forUpdating: url)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit { try? handle.close() }

    /// Queue an event without performing file I/O on the caller. JSON escaping
    /// keeps embedded newlines inside their event. A flooded queue retains the
    /// newest 128 events within a 512 KB budget rather than blocking the UI.
    public func append(sessionID: String, state: String, message: String) {
        let id = Self.bounded(sessionID, maximumBytes: 128)
        let phase = Self.bounded(state, maximumBytes: 128)
        let text = Self.bounded(message, maximumBytes: 8 * 1_024)
        logger.info("Session \(id, privacy: .public) \(phase, privacy: .public): \(text, privacy: .private)")
        let shouldSchedule = lock.withLock { () -> Bool in
            let event = Event(timestamp: Date(), sessionID: id, state: phase, message: text)
            pending.append(event); pendingBytes += event.byteCount
            while pending.count > 128 || pendingBytes > 512 * 1_024 {
                pendingBytes -= pending.removeFirst().byteCount
            }
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        if shouldSchedule { queue.async { [self] in drain() } }
    }

    /// Join queued writes and synchronize the file before exporting or quitting.
    /// False means a file write or synchronization failed during this journal.
    public func flush() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                drain()
                do { try handle.synchronize() }
                catch { hasWriteFailure = true }
                continuation.resume(returning: !hasWriteFailure)
            }
        }
    }

    private func drain() {
        while let event = lock.withLock({ () -> Event? in
            guard !pending.isEmpty else { drainScheduled = false; return nil }
            let event = pending.removeFirst()
            pendingBytes -= event.byteCount
            return event
        }) {
            write(event)
        }
    }

    private func write(_ event: Event) {
        do {
            if !checkedExistingTail {
                try repairIncompleteTail()
                checkedExistingTail = true
            }
            var encoded = try encoder.encode(event)
            encoded.append(10)
            let size = try handle.seekToEnd()
            if size + UInt64(encoded.count) > UInt64(Self.maximumFileBytes) {
                let retainedLimit = Self.maximumFileBytes / 2
                let start = size > UInt64(retainedLimit) ? size - UInt64(retainedLimit) : 0
                try handle.seek(toOffset: start)
                var retained = try handle.read(upToCount: retainedLimit) ?? Data()
                if start > 0 {
                    // The tail can start inside a UTF-8 scalar or JSON record;
                    // resume at the next complete physical event boundary.
                    if let newline = retained.firstIndex(of: 10) { retained.removeSubrange(...newline) }
                    else { retained.removeAll() }
                }
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: retained)
            }
            try handle.write(contentsOf: encoded)
        } catch {
            hasWriteFailure = true
            logger.error("Session diagnostics could not be saved: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func repairIncompleteTail() throws {
        let size = try handle.seekToEnd()
        guard size > 0 else { return }
        let tailLimit: UInt64 = 64 * 1_024
        let start = size > tailLimit ? size - tailLimit : 0
        try handle.seek(toOffset: start)
        let tail = try handle.read(upToCount: Int(tailLimit)) ?? Data()
        guard tail.last != 10 else { return }
        // A prior interrupted write may have left a partial JSON object. Every
        // event we produce is smaller than this bounded tail read.
        let completeEnd = tail.lastIndex(of: 10).map { start + UInt64($0) + 1 } ?? 0
        try handle.truncate(atOffset: completeEnd)
    }

    private static func bounded(_ text: String, maximumBytes: Int) -> String {
        var bytes = Data(text.utf8.prefix(maximumBytes + 1))
        guard bytes.count > maximumBytes else { return text }
        bytes.removeLast()
        while !bytes.isEmpty && String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self) + "…"
    }
}

import Foundation

/// scrcpy clipboard replies do not carry request IDs. Retain an unanswered
/// request after timeout/cancellation so a late reply cannot satisfy a newer
/// request or change the Mac clipboard after its action was cancelled.
final class ClipboardReplyChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: UUID?
    private var continuation: CheckedContinuation<String, Error>?
    private var closed = false

    func request(timeout: TimeInterval = 3, send: @escaping @Sendable () -> Void) async throws -> String {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                let accepted: Bool = lock.withLock {
                    guard !closed else { reply.resume(throwing: ScrcpyError.transport("The Android display is disconnected.")); return false }
                    guard waiting == nil else {
                        reply.resume(throwing: ScrcpyError.transport("A previous Android clipboard request is still unanswered. Reconnect Display to retry.")); return false
                    }
                    waiting = id; continuation = reply
                    return true
                }
                guard accepted else { return }
                // Even if cancelled just after registration, send once so the
                // eventual reply can be consumed without being misattributed.
                if Task.isCancelled { fail(id: id, error: CancellationError()) }
                send()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, timeout)) { [weak self] in
                    self?.fail(id: id, error: ScrcpyError.transport("Android returned no text clipboard. Copy text in Android, then reconnect the display if needed."))
                }
            }
        } onCancel: { self.fail(id: id, error: CancellationError()) }
    }

    func receive(_ text: String) {
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard !closed else { return nil }
            let result = continuation; continuation = nil; waiting = nil
            return result
        }
        pending?.resume(returning: text)
    }

    func close() {
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            closed = true; waiting = nil
            let result = continuation; continuation = nil; return result
        }
        pending?.resume(throwing: CancellationError())
    }

    private func fail(id: UUID, error: Error) {
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard waiting == id else { return nil }
            let result = continuation; continuation = nil; return result
        }
        pending?.resume(throwing: error)
    }
}

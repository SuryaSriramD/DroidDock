import Foundation
import Darwin

/// One continuous, device-scoped logcat process. Callbacks run on a utility
/// queue; consumers may pause presentation without stopping the pipe reader.
/// Lines, queued batches, and diagnostic output all have fixed memory bounds.
public final class LogcatStream: @unchecked Sendable {
    private let adb: ADBService
    private let queue = DispatchQueue(label: "app.androidsimulator.logcat", qos: .utility)
    private var process: Process?
    private var readers: [DispatchSourceRead?] = [nil, nil]
    private var batchTimer: DispatchSourceTimer?
    private var started = false
    private var stopping = false
    private var completed = false
    private var exitStatus: Int32?
    private var ended = [false, false]
    private var parser = LogcatLineBuffer()
    private var errorTail = Data()
    private var pendingLines: [String] = []
    private var pendingBytes = 0
    private var onLines: (@Sendable ([String]) -> Void)?
    private var onError: (@Sendable (String) -> Void)?
    private var readError: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(adb: ADBService) { self.adb = adb }

    deinit {
        process?.terminationHandler = nil
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        for reader in readers { reader?.cancel() }
        batchTimer?.cancel()
    }

    /// A stream is single-use. Create a new instance when reconnecting.
    public func start(onLines: @escaping @Sendable ([String]) -> Void,
                      onError: @escaping @Sendable (String) -> Void) throws {
        try queue.sync {
            guard !started, !stopping else {
                throw RuntimeError.invalidArgument("This Logcat stream has already been started or stopped.")
            }
            guard !adb.serial.isEmpty, !adb.serial.contains("\0") else {
                throw RuntimeError.invalidArgument("A device serial is required for Logcat.")
            }
            started = true
            self.onLines = onLines; self.onError = onError
            let child = Process(), output = Pipe(), errors = Pipe()
            child.executableURL = adb.sdk.adb
            child.arguments = ["-s", adb.serial, "logcat", "-v", "threadtime", "-T", "300"]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            child.standardError = errors
            child.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                self?.queue.async { [weak self] in self?.didExit(status: status) }
            }
            do { try child.run() }
            catch {
                child.terminationHandler = nil
                completed = true
                self.onLines = nil; self.onError = nil
                for pipe in [output, errors] {
                    try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close()
                }
                throw error
            }
            process = child
            for (index, pipe) in [output, errors].enumerated() {
                try? pipe.fileHandleForWriting.close()
                let handle = pipe.fileHandleForReading
                let descriptor = handle.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL)
                _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                source.setEventHandler { [weak self] in self?.drain(descriptor, index: index) }
                // The source exclusively owns this read handle, including close.
                source.setCancelHandler { try? handle.close() }
                readers[index] = source
                source.resume()
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.flushBatch() }
            batchTimer = timer
            timer.resume()
        }
    }

    /// Stop and reap only this stream's adb client. No device or ADB server is
    /// stopped. Awaiting this method joins process exit and closes both readers.
    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard started, !completed else {
                    stopping = true
                    continuation.resume(); return
                }
                waiters.append(continuation)
                guard !stopping else { return }
                stopping = true
                pendingLines.removeAll(); pendingBytes = 0
                if let process, process.isRunning { process.terminate() }
                queue.asyncAfter(deadline: .now() + .milliseconds(750)) { [weak self] in
                    guard let self, !self.completed, let process = self.process, process.isRunning else { return }
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                finishIfReady()
            }
        }
    }

    private func drain(_ descriptor: Int32, index: Int) {
        guard !ended[index] else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
        // Yield to stop, process-exit and batch callbacks even under a flood.
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                if index == 0 { append(parser.consume(bytes.prefix(count))) }
                else {
                    errorTail.append(contentsOf: bytes.prefix(count))
                    if errorTail.count > 8 * 1_024 { errorTail.removeFirst(errorTail.count - 8 * 1_024) }
                }
            } else if count == 0 {
                endReader(index); return
            } else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR {
                readError = "Logcat output could not be read: \(String(cString: strerror(errno)))"
                endReader(index)
                if let process, process.isRunning { process.terminate() }
                return
            }
        }
    }

    private func append(_ lines: [String]) {
        guard !stopping else { return }
        for line in lines {
            pendingLines.append(line); pendingBytes += line.utf8.count
            while pendingLines.count > 300 || pendingBytes > 512 * 1_024 {
                pendingBytes -= pendingLines.removeFirst().utf8.count
            }
        }
    }

    private func flushBatch() {
        guard !pendingLines.isEmpty else { return }
        let lines = pendingLines
        pendingLines.removeAll(keepingCapacity: true); pendingBytes = 0
        if !stopping { onLines?(lines) }
    }

    private func endReader(_ index: Int) {
        guard !ended[index] else { return }
        if index == 0 { append(parser.finish()) }
        ended[index] = true
        readers[index]?.cancel(); readers[index] = nil
        finishIfReady()
    }

    private func didExit(status: Int32) {
        exitStatus = status
        finishIfReady()
        // A misbehaving client can leave pipe writers inherited by a helper.
        // Closing our sources after the exact child has exited avoids a hang.
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self, !self.completed else { return }
            self.endReader(0); self.endReader(1)
        }
    }

    private func finishIfReady() {
        guard !completed, let exitStatus, ended.allSatisfy({ $0 }) else { return }
        completed = true
        batchTimer?.cancel(); batchTimer = nil
        flushBatch()
        if !stopping {
            let details = String(decoding: errorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            onError?(readError ?? "Logcat stopped (exit code \(exitStatus)).\(details.isEmpty ? "" : " " + details)")
        }
        onLines = nil; onError = nil
        process?.terminationHandler = nil; process = nil
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Retain incomplete UTF-8 across reads without allowing an unterminated line
/// to grow indefinitely. A truncated line is reported once at newline or EOF.
struct LogcatLineBuffer {
    static let maximumLineBytes = 64 * 1_024
    private var partial = Data()
    private var truncated = false

    mutating func consume<C: Collection>(_ bytes: C) -> [String] where C.Element == UInt8 {
        var lines: [String] = []
        for byte in bytes {
            if byte == 10 { lines.append(takeLine()) }
            else if partial.count < Self.maximumLineBytes { partial.append(byte) }
            else { truncated = true }
        }
        return lines
    }

    mutating func finish() -> [String] {
        partial.isEmpty && !truncated ? [] : [takeLine()]
    }

    private mutating func takeLine() -> String {
        if partial.last == 13 { partial.removeLast() }
        let line = String(decoding: partial, as: UTF8.self) + (truncated ? " … [line truncated]" : "")
        partial.removeAll(keepingCapacity: true); truncated = false
        return line
    }
}

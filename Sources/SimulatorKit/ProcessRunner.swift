import Foundation
import Darwin

/// Executes argument arrays directly. Each stream has a hard memory limit, and
/// timeout/cancellation terminates only the Process created for this invocation.
public enum ProcessRunner {
    public static let maximumOutputBytes = 32 * 1_024 * 1_024

    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        guard timeout > 0, timeout.isFinite else {
            throw RuntimeError.invalidArgument("A command timeout must be a positive, finite number.")
        }
        let execution = CommandExecution(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execution.execute() })
                }
            }
        } onCancel: {
            execution.cancel(with: CancellationError())
        }
    }
}

private final class CapturedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let remaining = ProcessRunner.maximumOutputBytes - data.count
        data.append(chunk.prefix(max(0, remaining)))
        return chunk.count <= remaining
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class CommandExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private var cancellation: Error?
    private var finished = false
    private var launched = false

    init(executable: URL, arguments: [String], timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }

    func cancel(with error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if cancellation == nil { cancellation = error }
        let shouldStop = launched && process.isRunning
        if shouldStop { process.terminate() }
        lock.unlock()
        if shouldStop {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                defer { lock.unlock() }
                if !finished, launched, process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    func execute() throws -> CommandResult {
        let out = Pipe()
        let err = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

        lock.lock()
        if let cancellation {
            finished = true
            lock.unlock()
            throw cancellation
        }
        do {
            try process.run()
            launched = true
            lock.unlock()
        } catch {
            finished = true
            lock.unlock()
            throw error
        }

        // Close our writer copies so the readers reliably reach EOF at exit.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        let stdout = CapturedBytes()
        let stderr = CapturedBytes()
        let readers = DispatchGroup()
        for (handle, capture) in [(out.fileHandleForReading, stdout), (err.fileHandleForReading, stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { try? handle.close(); readers.leave() }
                do {
                    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                        if !capture.append(chunk) {
                            cancel(with: RuntimeError.outputLimitExceeded(executable.lastPathComponent))
                        }
                    }
                } catch {
                    cancel(with: error)
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            cancel(with: RuntimeError.commandTimedOut(executable.lastPathComponent, timeout))
        }

        process.waitUntilExit()
        // Binaries can fork background helpers. Do not wait forever for inherited
        // pipe descriptors after the command itself has exited.
        if readers.wait(timeout: .now() + 2) == .timedOut {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        lock.lock()
        finished = true
        let error = cancellation
        lock.unlock()
        if let error { throw error }
        return CommandResult(stdout: stdout.value, stderr: stderr.value, status: process.terminationStatus)
    }
}

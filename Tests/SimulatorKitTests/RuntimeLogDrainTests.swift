import XCTest
import Darwin
@testable import SimulatorKit

final class RuntimeLogDrainTests: XCTestCase {
    func testEOFCompletionIncludesLargeFinalStdoutAndStderrBeforeCapture() async throws {
        let log = try logURL()
        let logger = try EmulatorLog(url: log)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-e", "print STDOUT 'o' x 262144; print STDERR 'final-stderr-marker'; exit 42"]
        child.standardOutput = logger.output; child.standardError = logger.output
        try child.run()
        logger.begin()
        let completed = await logger.completion.wait(timeout: 3)
        XCTAssertTrue(completed)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 42)
        let captured = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(captured, String(repeating: "o", count: 262_144) + "final-stderr-marker")
    }

    func testOpenWriterTimesOutButCancelledWaitStillJoinsLaterEOF() async throws {
        let log = try logURL()
        let logger = try EmulatorLog(url: log)
        let descriptor = Darwin.dup(logger.output.fileHandleForWriting.fileDescriptor)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? writer.close() }
        logger.begin()
        let start = ProcessInfo.processInfo.systemUptime
        let initial = await logger.completion.wait(timeout: 0.05)
        XCTAssertFalse(initial, "An inherited writer must not make EOF wait unbounded")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let cancelled = Task { await logger.completion.wait(timeout: 2) }
        cancelled.cancel()
        try writer.write(contentsOf: Data("late stderr retained".utf8))
        try writer.close()
        let completed = await cancelled.value
        XCTAssertTrue(completed, "Cancellation must not skip the bounded EOF join")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "late stderr retained")
        let repeated = await logger.completion.wait(timeout: 0)
        XCTAssertTrue(repeated, "Completed readers remain complete for later evidence capture")
    }

    private func logURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-log-drain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("runtime.log")
    }
}

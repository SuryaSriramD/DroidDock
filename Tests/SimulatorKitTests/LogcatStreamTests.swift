import XCTest
import Darwin
@testable import SimulatorKit

final class LogcatStreamTests: XCTestCase {
    private func fixture(_ body: String) throws -> ADBService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LogcatTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("adb")
        try Data(("#!/usr/bin/perl\n$| = 1; select STDERR; $| = 1; select STDOUT;\n" + body).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return ADBService(sdk: SDKInstallation(root: root, emulator: script, adb: script), serial: "emulator-fixture")
    }

    func testContinuousStreamDeliversSmallOutputBeforeExitAndStopsExactChild() async throws {
        let adb = try fixture("""
        $SIG{TERM} = sub {};
        print join(' ', @ARGV), "\\nPID $$\\n";
        while (1) { select undef, undef, undef, 0.1; }
        """)
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["20"]
        try other.run()
        defer { if other.isRunning { other.terminate() }; other.waitUntilExit() }
        let received = expectation(description: "Live lines before process exit")
        let capture = LogcatCapture()
        let stream = LogcatStream(adb: adb)
        try stream.start(onLines: { lines in capture.append(lines); received.fulfill() }, onError: { capture.fail($0) })
        XCTAssertThrowsError(try stream.start(onLines: { _ in }, onError: { _ in }))
        await fulfillment(of: [received], timeout: 2)
        let lines = capture.lines
        XCTAssertTrue(lines.contains("-s emulator-fixture logcat -v threadtime -T 300"))
        let pid = try XCTUnwrap(lines.first(where: { $0.hasPrefix("PID ") }).flatMap { Int32($0.dropFirst(4)) })
        XCTAssertEqual(Darwin.kill(pid, 0), 0, "Output must arrive while the logcat client is still running")
        let start = Date()
        await stream.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Stop must reap its exact client, even when it ignores SIGTERM")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(other.isRunning, "An unrelated child must not be stopped")
        XCTAssertTrue(capture.errors.isEmpty, "An intentional stop is not an error")
        await stream.stop()
    }

    func testExitDrainsUnterminatedLineAndReportsBoundedStderr() async throws {
        let adb = try fixture("print STDOUT 'final line'; print STDERR 'x' x 9000, ' fixture error'; exit 7;")
        let ended = expectation(description: "Unexpected exit")
        let capture = LogcatCapture()
        let stream = LogcatStream(adb: adb)
        try stream.start(onLines: { capture.append($0) }, onError: { capture.fail($0); ended.fulfill() })
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertEqual(capture.lines, ["final line"])
        let error = try XCTUnwrap(capture.errors.first)
        XCTAssertTrue(error.contains("exit code 7"))
        XCTAssertTrue(error.hasSuffix("fixture error"))
        XCTAssertLessThan(error.utf8.count, 8400)
        await stream.stop()
    }

    func testLineBufferPreservesSplitUTF8AndBoundsUnterminatedLines() {
        var buffer = LogcatLineBuffer()
        let text = Array("🙂 日本語\r\n".utf8)
        XCTAssertEqual(buffer.consume(text.prefix(2)), [])
        XCTAssertEqual(buffer.consume(text.dropFirst(2)), ["🙂 日本語"])
        XCTAssertEqual(buffer.consume(repeatElement(UInt8(97), count: 2 * LogcatLineBuffer.maximumLineBytes)), [])
        let truncated = buffer.consume([10])
        XCTAssertEqual(truncated.count, 1)
        XCTAssertTrue(truncated[0].hasSuffix("[line truncated]"))
        XCTAssertLessThan(truncated[0].utf8.count, LogcatLineBuffer.maximumLineBytes + 30)
        XCTAssertEqual(buffer.consume(Array("next\nlast".utf8)), ["next"])
        XCTAssertEqual(buffer.finish(), ["last"])
        XCTAssertEqual(buffer.finish(), [])
    }

    func testFloodKeepsLineAndCallbackBatchesBounded() async throws {
        let adb = try fixture("for (1..30) { print STDOUT 'a' x 70000, \"\\n\"; }")
        let ended = expectation(description: "Flood finished")
        let capture = LogcatCapture()
        let stream = LogcatStream(adb: adb)
        try stream.start(onLines: { capture.append($0) }, onError: { _ in ended.fulfill() })
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertFalse(capture.lines.isEmpty)
        XCTAssertTrue(capture.lines.allSatisfy { $0.hasSuffix("[line truncated]") && $0.utf8.count < 65_566 })
        XCTAssertLessThanOrEqual(capture.maximumBatchCount, 300)
        XCTAssertLessThanOrEqual(capture.maximumBatchBytes, 512 * 1_024)
        await stream.stop()
    }

    func testStoppedStreamCannotLaunch() async throws {
        let stream = LogcatStream(adb: try fixture("sleep 20;"))
        await stream.stop()
        XCTAssertThrowsError(try stream.start(onLines: { _ in }, onError: { _ in }))
    }
}

private final class LogcatCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedLines: [String] = []
    private var capturedErrors: [String] = []
    private var largestBatchCount = 0
    private var largestBatchBytes = 0
    var lines: [String] { lock.withLock { capturedLines } }
    var errors: [String] { lock.withLock { capturedErrors } }
    var maximumBatchCount: Int { lock.withLock { largestBatchCount } }
    var maximumBatchBytes: Int { lock.withLock { largestBatchBytes } }
    func append(_ lines: [String]) {
        lock.withLock {
            capturedLines.append(contentsOf: lines)
            largestBatchCount = max(largestBatchCount, lines.count)
            largestBatchBytes = max(largestBatchBytes, lines.reduce(0) { $0 + $1.utf8.count })
        }
    }
    func fail(_ message: String) { lock.withLock { capturedErrors.append(message) } }
}

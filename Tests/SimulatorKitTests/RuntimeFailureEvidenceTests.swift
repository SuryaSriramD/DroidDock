import XCTest
@testable import SimulatorKit

final class RuntimeFailureEvidenceTests: XCTestCase {
    func testAutomaticRetentionUsesOnlyEightFixedSlotsAndPreservesUnrelatedFiles() async throws {
        let root = try directory()
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let unrelated = output.appendingPathComponent("keep.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        let log = root.appendingPathComponent("emulator.log")
        let store = RuntimeFailureEvidenceStore(directoryURL: output)
        var last: RuntimeFailureEvidenceStore.Record?
        for index in 0...RuntimeFailureEvidenceStore.maximumArchives {
            try Data("runtime-tail-\(index)\n".utf8).write(to: log)
            let exit = makeExit(status: Int32(index))
            last = await store.preserve(exit: exit, diagnosticsString: "Captured before cleanup",
                runtimeLogURL: log, journalURL: nil, logLinesString: nil)
            XCTAssertNotNil(last?.archiveURL)
            XCTAssertNil(last?.warning)
            XCTAssertEqual(last?.exit, exit)
        }
        let members = try FileManager.default.contentsOfDirectory(atPath: output.path)
        XCTAssertEqual(Set(members), Set((0..<8).map { "runtime-exit-\($0).zip" } + ["keep.txt"]))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "unrelated")
        let archive = try XCTUnwrap(last?.archiveURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertLessThanOrEqual((attributes[.size] as? NSNumber)?.intValue ?? Int.max, DiagnosticsBundle.maximumArchiveBytes)
        let contents = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", archive.path, "diagnostics.txt"])
        try contents.requireSuccess(operation: "Read retained failure evidence")
        XCTAssertTrue(contents.text.contains("Exit status: 8"))
        XCTAssertTrue(contents.text.contains("runtime-tail-8"))
    }

    func testUnavailableDestinationRetainsExitAndBoundedUnicodeRuntimeTail() async throws {
        let root = try directory()
        let output = root.appendingPathComponent("blocked")
        try Data("leave this file unchanged".utf8).write(to: output)
        let log = root.appendingPathComponent("runtime.log")
        let text = (0..<40).map { "line \($0) " + String(repeating: "🙂", count: 200) }.joined(separator: "\n") + "\nlast-runtime-error"
        try Data(text.utf8).write(to: log)
        let exit = makeExit(status: 42)
        let result = await RuntimeFailureEvidenceStore(directoryURL: output).preserve(exit: exit,
            diagnosticsString: "identity already captured", runtimeLogURL: log, journalURL: nil, logLinesString: nil)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.exit, exit)
        XCTAssertNil(result.archiveURL)
        XCTAssertNotNil(result.warning)
        XCTAssertTrue(result.recentOutput.hasSuffix("last-runtime-error"))
        XCTAssertFalse(result.recentOutput.contains("\u{FFFD}"))
        XCTAssertLessThanOrEqual(result.recentOutput.utf8.count, RuntimeFailureEvidenceStore.maximumInlineLogBytes)
        XCTAssertLessThanOrEqual(result.recentOutput.split(separator: "\n").count, 20)
        XCTAssertTrue(result.message.contains("status 42"))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "leave this file unchanged")
    }

    func testIncompleteDrainWarningIsRetainedInSuccessfulBundle() async throws {
        let root = try directory()
        let log = root.appendingPathComponent("runtime.log")
        try Data("available output".utf8).write(to: log)
        let warning = "Runtime log EOF was not observed within 2 seconds; the captured stdout/stderr tail and emulator.log may be incomplete."
        let record = await RuntimeFailureEvidenceStore(directoryURL: root.appendingPathComponent("failures"))
            .preserve(exit: makeExit(status: 42), diagnosticsString: "session", runtimeLogURL: log,
                      journalURL: nil, logLinesString: nil, runtimeLogWarning: warning)
        XCTAssertEqual(record.warning, warning)
        XCTAssertTrue(record.message.contains(warning))
        let archive = try XCTUnwrap(record.archiveURL)
        let contents = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", archive.path, "diagnostics.txt"])
        try contents.requireSuccess(operation: "Read incomplete-tail evidence")
        XCTAssertTrue(contents.text.contains(warning))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("failure evidence \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func makeExit(status: Int32) -> RuntimeFailureEvidenceStore.Exit {
        .init(runtimeID: UUID(), sessionID: UUID(), processID: 12345, serial: "emulator-5554",
              avdName: "Fixture", consolePort: 5554, status: status, reason: "normal exit")
    }
}

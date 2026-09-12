import XCTest
@testable import SimulatorKit

final class DiagnosticsJournalTests: XCTestCase {
    private func logURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JournalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("session.jsonl")
    }

    func testJournalEscapesRecordsAndPreservesThemAcrossOpen() async throws {
        let url = try logURL()
        var log: SessionEventLog? = try SessionEventLog(url: url)
        let message = "line one\nline two\t\"日本語🙂\""
        log?.append(sessionID: "session-1", state: "running", message: message)
        let firstFlushed = await log!.flush()
        XCTAssertTrue(firstFlushed)
        log = nil
        let reopened = try SessionEventLog(url: url)
        reopened.append(sessionID: "session-1", state: "idle", message: "Stopped")
        let secondFlushed = await reopened.flush()
        XCTAssertTrue(secondFlushed)
        let records = try parse(url)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["message"] as? String, message)
        XCTAssertEqual(records[0]["sessionID"] as? String, "session-1")
        XCTAssertEqual(records[0]["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(records[0]["timestamp"])
        XCTAssertEqual(records[1]["state"] as? String, "idle")
    }

    func testRotationRetainsOnlyCompleteBoundedJSONLines() async throws {
        let url = try logURL()
        let log = try SessionEventLog(url: url)
        // Flush each moderate batch to exercise disk rotation independently of
        // the intentional pending-event flood bound.
        for batch in 0..<16 {
            for index in 0..<24 {
                log.append(sessionID: "session", state: "connecting", message: "\(batch)-\(index) " + String(repeating: "x", count: 9000))
            }
            let flushed = await log.flush()
            XCTAssertTrue(flushed)
        }
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, SessionEventLog.maximumFileBytes)
        let records = try parse(url)
        XCTAssertGreaterThan(records.count, 0)
        XCTAssertLessThan(records.count, 384)
        XCTAssertTrue((records.last?["message"] as? String)?.hasPrefix("15-23 ") == true)
        XCTAssertTrue(records.allSatisfy { (($0["message"] as? String)?.utf8.count ?? .max) <= 8195 })
    }

    func testInterruptedRecordIsRemovedBeforeAppending() async throws {
        let url = try logURL()
        try Data("{\"state\":\"earlier\"}\n{\"partial\":".utf8).write(to: url)
        let log = try SessionEventLog(url: url)
        log.append(sessionID: "session", state: "starting", message: "Starting again")
        let flushed = await log.flush()
        XCTAssertTrue(flushed)
        let records = try parse(url)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["state"] as? String, "earlier")
        XCTAssertEqual(records[1]["state"] as? String, "starting")
    }

    private func parse(_ url: URL) throws -> [[String: Any]] {
        try Data(contentsOf: url).split(separator: 10).map { bytes in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        }
    }
}

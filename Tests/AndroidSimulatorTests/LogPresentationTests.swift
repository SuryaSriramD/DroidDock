import XCTest
import Combine
import SimulatorKit
@testable import AndroidSimulator

@MainActor
final class LogPresentationTests: XCTestCase {
    func testLogAppendAndPauseNotifyOnlyTheLogViewport() async throws {
        let session = try makeSession()
        var sessionChanges = 0, logChanges = 0
        let sessionSubscription = session.objectWillChange.sink { sessionChanges += 1 }
        let logSubscription = session.logPresentation.objectWillChange.sink { logChanges += 1 }
        defer { sessionSubscription.cancel(); logSubscription.cancel() }

        XCTAssertTrue(session.logPresentation.append(["first message", "second message"]))
        XCTAssertEqual(session.logLines, ["first message", "second message"])
        XCTAssertEqual(session.filteredLogText(matching: "SECOND"), "second message")
        let revision = session.logPresentation.revision
        session.logPaused = true
        XCTAssertFalse(session.logPresentation.append(["discarded while paused"]))
        XCTAssertEqual(session.logPresentation.revision, revision)
        XCTAssertEqual(session.logPresentation.text, "first message\nsecond message")
        session.logPaused = false
        XCTAssertTrue(session.logPresentation.append(["resumed message"]))
        XCTAssertEqual(session.logLines.last, "resumed message")
        XCTAssertFalse(session.logLines.contains("discarded while paused"))
        XCTAssertGreaterThan(logChanges, 0)
        XCTAssertEqual(sessionChanges, 0, "Log traffic and Pause must not invalidate the device or library observers")
    }

    func testDisplayedDiagnosticsStayCachedAndReopenRefreshesWithoutChangingFreshExports() async throws {
        let session = try makeSession()
        session.setDeveloperPanel(.diagnostics)
        let initial = session.displayedDiagnostics
        XCTAssertTrue(initial.contains("State: idle"))
        session.logPresentation.append(["log event does not change the displayed diagnostic document"])
        XCTAssertEqual(session.displayedDiagnostics, initial)
        session.setDeveloperPanel(nil)
        session.error = "Visible after reopening"
        XCTAssertTrue(session.diagnostics.contains("Visible after reopening"), "Copy and export read current diagnostics independently of the displayed cache")
        XCTAssertEqual(session.displayedDiagnostics, initial)
        session.setDeveloperPanel(.diagnostics)
        XCTAssertTrue(session.displayedDiagnostics.contains("Visible after reopening"))
    }

    private func makeSession() throws -> SessionController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("log-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SessionController(avd: AVD(name: "LogFixture"),
            sdk: SDKInstallation(root: root, emulator: root.appendingPathComponent("emulator"), adb: root.appendingPathComponent("adb")),
            runtimeLedger: RuntimeLedger(url: root.appendingPathComponent("ledger.json")),
            journalURL: root.appendingPathComponent("journal.jsonl"), isQuitting: { false })
    }
}

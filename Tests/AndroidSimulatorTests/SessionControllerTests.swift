import XCTest
import CoreMedia
import CoreVideo
import Combine
import Darwin
@testable import AndroidSimulator
@testable import SimulatorKit

/// Runs the production controller and process manager. The SDK is a temporary
/// executable fixture and the bridge is controlled in memory. No Android VM,
/// NSApplication, window, panel, pasteboard, or native input API is invoked.
@MainActor
final class SessionControllerTests: XCTestCase {
    func testInitialDisplayFailureRecoversWithoutReplacingBootedRuntime() async throws {
        let context = try context(failures: 1)
        context.controller.start()
        try await eventually("A runtime must launch", timeout: 5) { context.controller.runtime != nil }
        let runtime = try XCTUnwrap(context.controller.runtime)
        try await eventually("Initial bridge failure should recover", timeout: 8) { context.controller.state == .running }

        XCTAssertEqual(context.bridges.created.count, 2)
        XCTAssertEqual(context.controller.runtime?.id, runtime.id)
        XCTAssertTrue(runtime.process.isRunning)
        XCTAssertEqual(try context.sdk.launchCount(), 1)
        XCTAssertFalse(context.sdk.exists("runtime-terminated"), "Display negotiation failure must not stop a booted runtime")
        XCTAssertTrue(context.controller.canControl)
        XCTAssertNil(context.controller.error)
    }

    func testExhaustedRetriesRetainLivenessMonitoringAndObserveLaterRuntimeExit() async throws {
        let context = try context(failures: 100)
        context.controller.start()
        try await eventually("A runtime must launch", timeout: 5) { context.controller.runtime != nil }
        let runtime = try XCTUnwrap(context.controller.runtime)
        try await eventually("Bridge retries should exhaust", timeout: 9) {
            context.controller.state == .failed && context.bridges.created.count == 4
        }
        XCTAssertTrue(runtime.process.isRunning)
        XCTAssertEqual(context.controller.runtime?.id, runtime.id)
        XCTAssertFalse(context.sdk.exists("runtime-terminated"))

        runtime.process.terminate() // This is the ordinary fixture child, not Android.
        try await eventually("Retained runtime exit must still be monitored", timeout: 4) { context.controller.runtime == nil }
        XCTAssertEqual(context.controller.state, .failed)
        XCTAssertTrue(context.controller.status.contains("unexpectedly"))
        XCTAssertTrue(context.controller.error?.contains("process exited") == true)
        XCTAssertFalse(context.controller.canUseADB)
        XCTAssertFalse(context.controller.canControl)
        XCTAssertEqual(try context.sdk.launchCount(), 1)
    }

    func testStopJoinsBackgroundDetachAndCannotPublishStaleBackgroundStatus() async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let bridge = try XCTUnwrap(context.bridges.created.first)
        let gate = bridge.holdStop()

        context.controller.setWindowVisible(false)
        try await eventually("Closing the view must start bridge detach", timeout: 2) { bridge.stopCount == 1 }
        let finished = CompletionFlag()
        let stop = Task { await context.controller.stop(); finished.value = true }
        try await eventually("Stop must enter Stopping", timeout: 2) { context.controller.state == .stopping }
        // Yield enough turns for an implementation that forgets the detached
        // bridge to proceed through its runtime stop. The gate stays closed.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(finished.value, "Stop must join the detached bridge's cleanup")
        XCTAssertTrue(runtime.process.isRunning, "The runtime cannot be released while bridge cleanup is blocked")

        await gate.open()
        try await eventually("Stop should finish after cleanup is released", timeout: 4) { finished.value }
        await stop.value
        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertEqual(context.controller.status, "Device stopped")
        XCTAssertNil(context.controller.runtime)
        XCTAssertFalse(runtime.process.isRunning)
        XCTAssertFalse(context.controller.hasPendingWork)
    }

    func testStopDuringLaunchCancelsSDKDiscoveryAndAllowsFreshStart() async throws {
        let context = try context()
        try context.sdk.mark("block-discovery")
        context.controller.start()
        try await eventually("Launch discovery should reach its gate", timeout: 5) { context.sdk.exists("discovery-blocked") }
        let discoveryPID = try context.sdk.pid("discovery-pid")
        XCTAssertEqual(context.controller.state, .starting)
        XCTAssertNil(context.controller.runtime)

        let finished = CompletionFlag()
        let stop = Task { await context.controller.stop(); finished.value = true }
        try await eventually("Stop must cancel launch discovery", timeout: 4) { finished.value }
        await stop.value
        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertEqual(context.bridges.created.count, 0)
        XCTAssertEqual(try context.sdk.launchCount(), 0)
        XCTAssertEqual(Darwin.kill(discoveryPID, 0), -1, "The cancelled SDK query must have exited")
        XCTAssertEqual(errno, ESRCH)

        try context.sdk.remove("block-discovery")
        try await start(context)
        XCTAssertEqual(try context.sdk.launchCount(), 1, "Cancellation must release the manager's starting reservation")
    }

    func testStopAfterRuntimeLaunchJoinsDelayedInitialBridgeAndAllowsFreshStart() async throws {
        let gate = AsyncGate()
        let context = try context(firstStartGate: gate)
        var publishedStates: [SessionState] = []
        let subscription = context.controller.$state.sink { publishedStates.append($0) }
        defer { subscription.cancel() }
        context.controller.start()
        try await eventually("The owned runtime should reach the gated initial bridge", timeout: 5) {
            context.bridges.created.first?.startCount == 1
        }
        let runtime = try XCTUnwrap(context.controller.runtime)
        let bridge = try XCTUnwrap(context.bridges.created.first)
        XCTAssertEqual(context.controller.state, .connecting)
        XCTAssertTrue(runtime.process.isRunning)
        XCTAssertFalse(bridge.startReturned)

        let finished = CompletionFlag()
        let stop = Task { await context.controller.stop(); finished.value = true }
        try await eventually("Stop should clean up the launched child while the old connection is pending", timeout: 4) {
            bridge.stopCount >= 1 && !runtime.process.isRunning
        }
        XCTAssertFalse(finished.value, "Stop must still join the delayed bridge start before reporting Idle")
        XCTAssertEqual(context.controller.state, .stopping)
        XCTAssertFalse(bridge.startReturned)

        // This fixture deliberately ignores cancellation and delivers its saved
        // callback after Stop, modeling an already in-flight decoder callback.
        await gate.open()
        try await eventually("Stop should finish after the late bridge completion", timeout: 3) { finished.value }
        await stop.value
        XCTAssertTrue(bridge.startReturned)
        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertEqual(context.controller.status, "Device stopped")
        XCTAssertNil(context.controller.runtime)
        XCTAssertFalse(context.controller.displayAttached)
        XCTAssertFalse(context.controller.canControl)
        XCTAssertFalse(publishedStates.contains(.running), "A late successful callback cannot resurrect a cancelled launch")
        XCTAssertNil(context.controller.frames.take(), "The frame store must reject a retired stream's late frame")
        XCTAssertEqual(Darwin.kill(runtime.process.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        try await start(context)
        XCTAssertEqual(try context.sdk.launchCount(), 2)
        XCTAssertEqual(context.bridges.created.count, 2)
        XCTAssertNotEqual(context.controller.runtime?.id, runtime.id)
        XCTAssertTrue(context.controller.runtime?.process.isRunning == true)
    }

    func testLeaveRunningForQuitJoinsBridgeAndLogsAndPersistsFreshRuntimeIdentity() async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let bridge = try XCTUnwrap(context.bridges.created.first)
        let originalIdentity = try XCTUnwrap(RuntimeLedger.nativeIdentity(runtime.process.processIdentifier))
        XCTAssertNil(context.controller.historyWarning)
        try context.sdk.mark("logcat-ignore-term")
        context.controller.startLogs()
        try await eventually("The active Logcat reader should start", timeout: 3) { context.sdk.exists("logcat-pid") }
        let logcatPID = try context.sdk.pid("logcat-pid")
        let gate = bridge.holdStop()

        let finished = CompletionFlag()
        let leave = Task { await context.controller.leaveRunningForQuit(); finished.value = true }
        try await eventually("Leave-running cleanup should reach bridge Stop", timeout: 2) { bridge.stopCount == 1 }
        XCTAssertFalse(finished.value)
        XCTAssertTrue(runtime.process.isRunning)
        XCTAssertFalse(context.controller.displayAttached)
        await gate.open()
        try await eventually("Leave-running should join bridge and Logcat cleanup", timeout: 4) { finished.value }
        await leave.value

        XCTAssertTrue(runtime.process.isRunning, "Quit's leave-running policy must preserve its owned child")
        XCTAssertEqual(context.controller.runtime?.id, runtime.id)
        XCTAssertFalse(context.controller.canControl)
        XCTAssertFalse(context.controller.hasPendingWork)
        XCTAssertFalse(context.sdk.exists("runtime-terminated"))
        XCTAssertEqual(Darwin.kill(logcatPID, 0), -1, "The active Logcat child must be fully reaped before quit cleanup returns")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(RuntimeLedger.nativeIdentity(runtime.process.processIdentifier), originalIdentity)

        let ledgerURL = context.sdk.root.appendingPathComponent("ledger.json")
        // Reopen the file and rediscover via the selected fake SDK. Neither
        // result comes from the controller's in-memory runtime reference.
        let freshLedger = RuntimeLedger(url: ledgerURL)
        let discovered = try await ADBService.devices(sdk: context.sdk.installation)
        let matches = try await freshLedger.inspect(discovered: discovered, sdk: context.sdk.installation)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.runtimeID, runtime.id)
        XCTAssertEqual(matches.first?.pid, originalIdentity.pid)
        XCTAssertEqual(matches.first?.executablePath, originalIdentity.executablePath)
        XCTAssertEqual(matches.first?.disposition, .intentionallyLeftRunning)

        let stopped = CompletionFlag()
        let stop = Task { await context.controller.stop(); stopped.value = true }
        try await eventually("Explicit Stop should still clean up the retained child", timeout: 4) { stopped.value }
        await stop.value
        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertFalse(runtime.process.isRunning)
        XCTAssertNil(context.controller.runtime)
        let stored = try JSONDecoder().decode(RuntimeLedger.Document.self, from: Data(contentsOf: ledgerURL))
        XCTAssertTrue(stored.entries.isEmpty, "Stop must remove the persisted record, not merely make its process identity unmatchable")
        XCTAssertFalse(context.sdk.exists("runtime-stopped-with-live-logcat"))
    }

    func testADBDegradationPreservesDisplayAndRecoversDependentActions() async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let bridge = try XCTUnwrap(context.bridges.created.first)
        try context.sdk.mark("adb-offline")
        try await eventually("Health sampling should mark ADB unavailable", timeout: 8) { !context.controller.adbAvailable }
        try bridge.emitFrame()

        XCTAssertEqual(context.controller.state, .running)
        XCTAssertEqual(context.controller.runtime?.id, runtime.id)
        XCTAssertTrue(context.controller.displayAttached)
        XCTAssertTrue(context.controller.canControl, "A surviving direct display/control stream does not depend on ADB availability")
        XCTAssertFalse(context.controller.canUseADB)
        XCTAssertEqual(context.bridges.created.count, 1)
        XCTAssertEqual(bridge.stopCount, 0)

        try context.sdk.remove("adb-offline")
        try await eventually("Health sampling should recover ADB actions", timeout: 8) { context.controller.canUseADB }
        XCTAssertEqual(context.controller.runtime?.id, runtime.id)
        XCTAssertEqual(context.bridges.created.count, 1)
    }

    func testStopJoinsPreviouslyRetiredLogcatBeforeStoppingRuntime() async throws {
        let context = try context()
        try await start(context)
        try context.sdk.mark("logcat-ignore-term")
        context.controller.startLogs()
        try await eventually("The selected-device log reader must start", timeout: 3) { context.sdk.exists("logcat-pid") }
        let logcatPID = try context.sdk.pid("logcat-pid")
        XCTAssertEqual(Darwin.kill(logcatPID, 0), 0)

        // Hiding the panel retires the reader before Stop captures active work.
        context.controller.stopLogs()
        let finished = CompletionFlag()
        let stop = Task { await context.controller.stop(); finished.value = true }
        try await eventually("Stop should join retired Logcat cleanup", timeout: 4) { finished.value }
        await stop.value

        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertFalse(context.sdk.exists("runtime-stopped-with-live-logcat"),
                       "The fixture runtime checks reader liveness when it receives SIGTERM")
        XCTAssertTrue(context.sdk.exists("runtime-terminated"))
        XCTAssertEqual(Darwin.kill(logcatPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        try await eventually("Retired task bookkeeping should drain", timeout: 2) { !context.controller.hasPendingWork }
    }

    func testRapidLogsDiagnosticsSwitchJoinsRetiredReaderAndPreservesPausedTail() async throws {
        let context = try context()
        try await start(context)
        try context.sdk.mark("logcat-ignore-term")
        context.controller.setDeveloperPanel(.logs)
        try await eventually("The selected-device reader must supply its first line", timeout: 3) {
            context.sdk.exists("logcat-pid") && !context.controller.logLines.isEmpty
        }
        let firstPID = try context.sdk.pid("logcat-pid")
        let tail = context.controller.logLines
        context.controller.logPaused = true
        context.controller.setDeveloperPanel(.diagnostics)
        XCTAssertTrue(context.controller.displayedDiagnostics.contains("State: running"))
        // Reopening immediately must join the first reader's bounded retirement.
        context.controller.setDeveloperPanel(.logs)
        try await eventually("A fresh reader must replace the retired child", timeout: 4) {
            (try? context.sdk.pid("logcat-pid")).map { $0 != firstPID } ?? false
        }
        XCTAssertEqual(Darwin.kill(firstPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(context.controller.logPaused)
        XCTAssertEqual(context.controller.logLines, tail)
        let secondPID = try context.sdk.pid("logcat-pid")
        context.controller.setDeveloperPanel(.diagnostics)
        try await eventually("Diagnostics must leave no hidden Logcat reader", timeout: 4) {
            !context.controller.hasPendingWork && Darwin.kill(secondPID, 0) == -1
        }
        XCTAssertTrue(context.controller.runtime?.process.isRunning == true)
        XCTAssertEqual(context.controller.logLines, tail)
        XCTAssertEqual(try context.sdk.launchCount(), 1)
    }

    func testUnexpectedRuntimeExitPreservesIdentityOutputAndAutomaticBundleAfterCleanup() async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        try context.sdk.mark("exit-runtime")
        try await eventually("Unexpected exit must finish local evidence collection", timeout: 7) {
            context.controller.lastRuntimeFailure?.complete == true && !context.controller.hasPendingWork
        }
        let record = try XCTUnwrap(context.controller.lastRuntimeFailure)
        XCTAssertEqual(context.controller.state, .failed)
        XCTAssertNil(context.controller.runtime)
        XCTAssertFalse(context.controller.displayAttached)
        XCTAssertEqual(record.exit.runtimeID, runtime.id)
        XCTAssertEqual(record.exit.processID, runtime.process.processIdentifier)
        XCTAssertEqual(record.exit.serial, runtime.serial)
        XCTAssertEqual(record.exit.status, 42)
        XCTAssertEqual(record.exit.reason, "normal exit")
        XCTAssertTrue(context.controller.error?.contains("fixture-runtime-failure-42") == true)
        XCTAssertTrue(context.controller.diagnostics.contains("Exit owned PID: \(runtime.process.processIdentifier)"))
        let archive = try XCTUnwrap(record.archiveURL)
        XCTAssertTrue(archive.path.hasPrefix(context.sdk.root.path))
        let contents = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", archive.path, "diagnostics.txt"])
        try contents.requireSuccess(operation: "Read automatic failure bundle")
        XCTAssertTrue(contents.text.contains("Exit runtime ID: \(runtime.id.uuidString)"))
        XCTAssertTrue(contents.text.contains("fixture-runtime-failure-42"))
        let runtimeLog = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", archive.path, "emulator.log"])
        XCTAssertTrue(runtimeLog.text.contains("fixture-runtime-failure-42"))
        try context.sdk.remove("exit-runtime")
        try await start(context)
        XCTAssertNil(context.controller.lastRuntimeFailure)
        XCTAssertNil(context.controller.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path), "Restart does not delete preserved evidence")
    }

    func testOwnedExitDuringStartupAlsoPreservesEvidenceAndExportFailureIsActionable() async throws {
        let context = try context()
        let directory = context.sdk.root.appendingPathComponent("failure-evidence")
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data("blocked destination".utf8)))
        try context.sdk.mark("exit-runtime")
        context.controller.start()
        try await eventually("An owned startup exit must retain its diagnostic record", timeout: 7) {
            context.controller.lastRuntimeFailure?.complete == true && !context.controller.hasPendingWork
        }
        let record = try XCTUnwrap(context.controller.lastRuntimeFailure)
        XCTAssertEqual(record.exit.status, 42)
        XCTAssertNil(record.archiveURL)
        XCTAssertNotNil(record.warning)
        XCTAssertTrue(record.recentOutput.contains("fixture-runtime-failure-42"))
        XCTAssertTrue(context.controller.error?.contains("automatic bundle could not be saved") == true)
        XCTAssertNil(context.controller.runtime)
        XCTAssertEqual(try String(contentsOf: directory, encoding: .utf8), "blocked destination")
    }

    func testNormalStopDoesNotCreateUnexpectedExitEvidence() async throws {
        let context = try context()
        try await start(context)
        await context.controller.stop()
        XCTAssertNil(context.controller.lastRuntimeFailure)
        XCTAssertFalse(context.sdk.exists("failure-evidence"))
        XCTAssertEqual(context.controller.state, .idle)
    }

    func testVisibleDiagnosticsRefreshForStoppingIdleAndFreshStart() async throws {
        let context = try context()
        context.controller.setDeveloperPanel(.diagnostics)
        try await start(context)
        XCTAssertTrue(context.controller.displayedDiagnostics.contains("State: running\n"))
        let gate = try XCTUnwrap(context.bridges.created.first).holdStop()
        let finished = CompletionFlag()
        let stop = Task { await context.controller.stop(); finished.value = true }
        try await eventually("Stop reaches its gated cleanup", timeout: 2) { context.controller.state == .stopping }
        XCTAssertTrue(context.controller.displayedDiagnostics.contains("State: stopping\n"))
        await gate.open()
        try await eventually("Stop completes", timeout: 4) { finished.value }
        await stop.value
        XCTAssertTrue(context.controller.displayedDiagnostics.contains("State: idle\n"))
        XCTAssertTrue(context.controller.displayedDiagnostics.contains("Owned PID: —\n"))
        XCTAssertFalse(context.controller.displayedDiagnostics.contains("Surface stream:"))
        try await start(context)
        XCTAssertTrue(context.controller.displayedDiagnostics.contains("State: running\n"))
    }

    func testRuntimeExitDuringSnapshotRestartsMonitoringAndPreservesWithoutSelfAwait() async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        try context.sdk.mark("exit-during-snapshot")
        context.controller.performSnapshot(.save("fixture-save"), expectedRuntimeID: runtime.id)
        try await eventually("Snapshot exit must unwind and preserve evidence", timeout: 7) {
            context.controller.lastRuntimeFailure?.complete == true && !context.controller.hasPendingWork
        }
        XCTAssertTrue(context.sdk.exists("snapshot-command-started"))
        XCTAssertEqual(context.controller.state, .failed)
        XCTAssertNil(context.controller.runtime)
        XCTAssertFalse(context.controller.snapshotBusy)
        let record = try XCTUnwrap(context.controller.lastRuntimeFailure)
        XCTAssertEqual(record.exit.runtimeID, runtime.id)
        XCTAssertEqual(record.exit.status, 42)
        XCTAssertTrue(record.recentOutput.contains("fixture-runtime-failure-42"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.archiveURL).path))
        await context.controller.stop()
        XCTAssertEqual(context.controller.state, .idle)
    }

    func testUnsupportedSnapshotsDisableOnlyTheirRuntimeAndResetOnNewRuntime() async throws {
        let context = try context()
        try await start(context)
        try await eventually("Snapshot actions should become available after launch", timeout: 2) {
            context.controller.canManageSnapshots
        }
        let runtime = try XCTUnwrap(context.controller.runtime)
        context.controller.setDeveloperPanel(.diagnostics)

        // A transient console failure is not evidence of an unsupported feature.
        try context.sdk.mark("snapshot-failure")
        context.controller.performSnapshot(.refresh)
        try await eventually("The transient failure should finish", timeout: 3) {
            !context.controller.snapshotBusy && context.controller.error != nil
        }
        XCTAssertTrue(context.controller.canManageSnapshots)
        XCTAssertNil(context.controller.snapshotUnsupportedReason)
        try context.sdk.remove("snapshot-failure")

        try context.sdk.mark("snapshot-unsupported")
        context.controller.performSnapshot(.refresh)
        try await eventually("Explicit unsupported response should disable snapshot management", timeout: 3) {
            !context.controller.snapshotBusy && context.controller.snapshotUnsupportedReason != nil
        }
        let reason = try XCTUnwrap(context.controller.snapshotUnsupportedReason)
        XCTAssertTrue(reason.contains("Check the AVD’s snapshot support and launch settings"))
        XCTAssertTrue(reason.contains("Snapshots are disabled for this fixture"))
        XCTAssertEqual(context.controller.error, reason)
        XCTAssertFalse(context.controller.canManageSnapshots)
        XCTAssertTrue(context.controller.canUseADB)
        XCTAssertTrue(context.controller.canControl)
        XCTAssertEqual(context.controller.runtime?.id, runtime.id)
        XCTAssertEqual(try context.sdk.snapshotCommands(), ["\(runtime.serial) list", "\(runtime.serial) list"])

        context.controller.error = nil
        XCTAssertEqual(context.controller.snapshotUnsupportedReason, reason)
        XCTAssertTrue(context.controller.diagnostics.contains(reason))
        XCTAssertTrue(context.controller.displayedDiagnostics.contains(reason))
        context.controller.performSnapshot(.refresh)
        XCTAssertFalse(context.controller.snapshotBusy, "Disabled management must reject another console operation")
        XCTAssertEqual(try context.sdk.snapshotCommands().count, 2)

        context.controller.retryDisplay()
        try await eventually("Display reconnect should finish for the same runtime", timeout: 4) {
            context.bridges.created.count == 2 && context.controller.state == .running
        }
        XCTAssertEqual(context.controller.runtime?.id, runtime.id)
        XCTAssertEqual(context.controller.snapshotUnsupportedReason, reason)
        XCTAssertFalse(context.controller.canManageSnapshots)

        // The discovered limit belongs to this runtime, not its SDK version or
        // another selected session using the same command contract.
        let other = try self.context()
        try await start(other)
        try await eventually("Another session retains snapshot actions", timeout: 2) { other.controller.canManageSnapshots }
        XCTAssertNil(other.controller.snapshotUnsupportedReason)
        await other.controller.stop()

        await context.controller.stop()
        try context.sdk.remove("snapshot-unsupported")
        try await start(context)
        try await eventually("A genuinely new runtime resets discovered snapshot support", timeout: 2) {
            context.controller.canManageSnapshots
        }
        let replacement = try XCTUnwrap(context.controller.runtime)
        XCTAssertNotEqual(replacement.id, runtime.id)
        XCTAssertNil(context.controller.snapshotUnsupportedReason)
        context.controller.performSnapshot(.refresh)
        try await eventually("The new runtime should be queried successfully", timeout: 3) {
            !context.controller.snapshotBusy && context.controller.actionStatus == "Snapshots refreshed"
        }
        XCTAssertNil(context.controller.error)
        XCTAssertEqual(try context.sdk.snapshotCommands().last, "\(replacement.serial) list")
        XCTAssertEqual(try context.sdk.snapshotCommands().count, 3)
        XCTAssertFalse(context.controller.diagnostics.contains(reason))
    }

    func testStopDuringUnexpectedExitCleanupJoinsCancellationIndependentEvidence() async throws {
        let context = try context()
        try await start(context)
        let runtimeID = try XCTUnwrap(context.controller.runtime?.id)
        let bridge = try XCTUnwrap(context.bridges.created.first)
        let gate = bridge.holdStop()
        try context.sdk.mark("exit-runtime")
        try await eventually("Unexpected-exit cleanup must reach the gated bridge", timeout: 4) {
            context.controller.state == .failed && bridge.stopCount == 1
        }
        XCTAssertTrue(context.controller.hasPendingWork)
        let finished = CompletionFlag()
        let stop = Task { await context.controller.stop(); finished.value = true }
        try await eventually("Stop must enter its own lifecycle", timeout: 2) { context.controller.state == .stopping }
        XCTAssertFalse(finished.value)
        await gate.open()
        try await eventually("Stop must join automatic evidence before reporting Idle", timeout: 5) { finished.value }
        await stop.value
        let record = try XCTUnwrap(context.controller.lastRuntimeFailure)
        XCTAssertTrue(record.complete)
        XCTAssertEqual(record.exit.runtimeID, runtimeID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.archiveURL).path))
        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertEqual(context.controller.status, "Device stopped")
        XCTAssertFalse(context.controller.hasPendingWork)
    }

    private func start(_ context: ControllerContext) async throws {
        context.controller.start()
        try await eventually("Controller must reach Running", timeout: 6) { context.controller.state == .running }
    }

    private func context(failures: Int = 0, firstStartGate: AsyncGate? = nil) throws -> ControllerContext {
        let sdk = try FixtureSDK()
        let bridges = BridgeFactory(failures: failures, firstStartGate: firstStartGate)
        let controller = SessionController(avd: AVD(name: "Fixture_AVD", architecture: "arm64-v8a"), sdk: sdk.installation,
            manager: EmulatorProcessManager(logDirectory: sdk.root.appendingPathComponent("logs")),
            runtimeLedger: RuntimeLedger(url: sdk.root.appendingPathComponent("ledger.json")),
            journalURL: sdk.root.appendingPathComponent("journal.jsonl"),
            failureEvidenceStore: RuntimeFailureEvidenceStore(directoryURL: sdk.root.appendingPathComponent("failure-evidence")), isQuitting: { false },
            bridgeFactory: { _, _ in bridges.make() })
        let context = ControllerContext(controller: controller, sdk: sdk, bridges: bridges)
        addTeardownBlock { @MainActor in
            if let error = controller.error { print("Fixture controller ended \(controller.state): \(error)") }
            await bridges.releaseAllStops()
            // Every fixture executable has a shutdown marker and a hard lifetime
            // bound in addition to the production manager's exact-child stop.
            try? sdk.mark("shutdown")
            await controller.stop()
            try? FileManager.default.removeItem(at: sdk.root)
        }
        return context
    }

    private func eventually(_ message: String, timeout: TimeInterval,
                            condition: @MainActor () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail(message, file: file, line: line)
                throw FixtureFailure(message)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor private struct ControllerContext {
    let controller: SessionController
    let sdk: FixtureSDK
    let bridges: BridgeFactory
}

@MainActor private final class CompletionFlag { var value = false }

@MainActor private final class BridgeFactory {
    private var failures: Int
    private let firstStartGate: AsyncGate?
    private(set) var created: [FixtureBridge] = []
    init(failures: Int, firstStartGate: AsyncGate?) {
        self.failures = failures; self.firstStartGate = firstStartGate
    }
    func make() -> FixtureBridge {
        let bridge = FixtureBridge(failStart: failures > 0, startGate: created.isEmpty ? firstStartGate : nil)
        if failures > 0 { failures -= 1 }
        created.append(bridge)
        return bridge
    }
    func releaseAllStops() async {
        for bridge in created { await bridge.releaseStart(); await bridge.releaseStop() }
    }
}

private final class FixtureBridge: DisplayBridge, @unchecked Sendable {
    private let lock = NSLock()
    private let failStart: Bool
    private let starting: AsyncGate?
    private var frameCallback: (@Sendable (DecodedFrame) -> Void)?
    private var disconnectCallback: (@Sendable (String) -> Void)?
    private var stopping: AsyncGate?
    private var stopped = 0
    private var started = 0
    private var returned = false
    var stopCount: Int { lock.withLock { stopped } }
    var startCount: Int { lock.withLock { started } }
    var startReturned: Bool { lock.withLock { returned } }
    init(failStart: Bool, startGate: AsyncGate?) {
        self.failStart = failStart; self.starting = startGate
    }

    func start(onFrame: @escaping @Sendable (DecodedFrame) -> Void,
               onDisconnect: @escaping @Sendable (String) -> Void) async throws {
        if failStart { throw FixtureFailure("Injected display negotiation failure") }
        lock.withLock { frameCallback = onFrame; disconnectCallback = onDisconnect; started += 1 }
        await starting?.wait()
        defer { lock.withLock { returned = true } }
        onFrame(try makeFrame())
    }
    func stop() async {
        let gate = lock.withLock { () -> AsyncGate? in
            stopped += 1
            frameCallback = nil; disconnectCallback = nil
            return stopping
        }
        await gate?.wait()
    }
    func send(_ input: BridgeInput) { }
    func readClipboard() async throws -> String { throw FixtureFailure("Clipboard is outside this controller fixture") }
    func holdStop() -> AsyncGate {
        lock.withLock { let gate = AsyncGate(); stopping = gate; return gate }
    }
    func releaseStop() async { await lock.withLock { stopping }?.open() }
    func releaseStart() async { await starting?.open() }
    func emitFrame() throws {
        lock.withLock { frameCallback }?(try makeFrame())
    }
    private func makeFrame() throws -> DecodedFrame {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw FixtureFailure("Could not create the fixture pixel buffer") }
        let now = ProcessInfo.processInfo.systemUptime
        return DecodedFrame(pixelBuffer: buffer, presentationTime: .zero, receivedAt: now, decodedAt: now)
    }
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct FixtureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}

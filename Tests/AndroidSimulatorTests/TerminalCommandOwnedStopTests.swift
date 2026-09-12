import XCTest
import CoreMedia
import CoreVideo
import Darwin
@testable import AndroidSimulator
import SimulatorKit

@MainActor
final class TerminalCommandOwnedStopTests: XCTestCase {
    func testStopReportsIdleWithoutStaleDiscoveryIdentityAndReapsOwnedRuntime() async throws {
        let fixture = try FixtureSDK()
        let ledger = RuntimeLedger(url: fixture.root.appendingPathComponent("ledger.json"))
        let model = AppModel(runtimeLedger: ledger)
        model.sdkPath = fixture.installation.root.path
        model.stopOnQuit = true
        let avd = AVD(name: "Fixture_AVD", architecture: "arm64-v8a")
        let controller = SessionController(avd: avd, sdk: fixture.installation,
            manager: EmulatorProcessManager(logDirectory: fixture.root.appendingPathComponent("logs")),
            runtimeLedger: ledger, journalURL: fixture.root.appendingPathComponent("journal.jsonl"),
            failureEvidenceStore: RuntimeFailureEvidenceStore(directoryURL: fixture.root.appendingPathComponent("failure-evidence")),
            isQuitting: { model.isQuitting }, bridgeFactory: { _, _ in TerminalStopFixtureBridge() })
        // Register the controller directly: the production launch API also
        // creates a native window, which is outside this process fixture.
        model.sessions[avd.id] = controller
        addTeardownBlock { @MainActor in
            try? fixture.mark("shutdown")
            await model.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        controller.start()
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while controller.state != .running {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Fixture must reach Running: \(controller.state), \(controller.error ?? controller.status)")
                throw CocoaError(.executableRuntimeMismatch)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let runtime = try XCTUnwrap(controller.runtime)
        let pid = runtime.process.processIdentifier
        XCTAssertTrue(runtime.process.isRunning)
        await model.refresh()
        XCTAssertTrue(model.externalDevices.contains { $0.serial == runtime.serial },
                      "Discovery must include the live owned runtime before Stop to exercise the stale snapshot case")

        let handler = TerminalCommandHandler(model: model,
            store: SimulatorCommandStore(directory: fixture.root.appendingPathComponent("Commands", isDirectory: true)))
        let response = await handler.execute(SimulatorCommandRequest(action: .stop, device: avd.id))
        XCTAssertTrue(response.success, response.message)
        let stopped = try XCTUnwrap(response.devices.first)
        XCTAssertEqual(response.devices.count, 1)
        XCTAssertEqual(stopped.id, avd.id)
        XCTAssertEqual(stopped.state, "idle")
        XCTAssertFalse(stopped.isOwned)
        XCTAssertNil(stopped.serial, "The completed Stop response must not reuse pre-stop ADB discovery")
        XCTAssertNil(stopped.pid)
        XCTAssertEqual(stopped.sdkPath, fixture.installation.root.path)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.runtime)
        XCTAssertFalse(controller.hasPendingWork)
        XCTAssertFalse(runtime.process.isRunning)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(try fixture.launchCount(), 1)
    }
}

/// One in-memory pixel satisfies the production controller's first-frame gate;
/// the runtime and ADB commands are ordinary FixtureSDK Perl children.
private final class TerminalStopFixtureBridge: DisplayBridge, Sendable {
    func start(onFrame: @escaping @Sendable (DecodedFrame) -> Void,
               onDisconnect: @escaping @Sendable (String) -> Void) async throws {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw CocoaError(.coderInvalidValue) }
        let now = ProcessInfo.processInfo.systemUptime
        onFrame(DecodedFrame(pixelBuffer: buffer, presentationTime: .zero, receivedAt: now, decodedAt: now))
    }
    func stop() async { }
    func send(_ input: BridgeInput) { }
    func readClipboard() async throws -> String { throw CocoaError(.featureUnsupported) }
}

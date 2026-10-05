import XCTest
import CoreMedia
import CoreVideo
import Darwin
@testable import AndroidSimulator
@testable import SimulatorKit

/// Exercises the library action against temporary SDK executables and an
/// in-memory display. No Android installation, app window, or user data is used.
@MainActor
final class LibraryStopTests: XCTestCase {
    func testOwnedStopRefreshesDiscoveryAndAllowsEditingWithoutChangingPhoneData() async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let originalConfiguration = try Data(contentsOf: context.configURL)
        await context.model.refresh()
        XCTAssertTrue(context.model.externalDevices.contains { $0.serial == runtime.serial })
        context.model.presentAVDConfiguration(context.avd)
        XCTAssertNil(context.model.editingConfiguration)

        let request = try XCTUnwrap(context.model.stopRequest(for: context.avd))
        await context.model.stopDevice(request)

        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertNil(context.controller.runtime)
        XCTAssertFalse(context.controller.hasPendingWork)
        XCTAssertFalse(runtime.process.isRunning)
        XCTAssertEqual(Darwin.kill(runtime.process.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(context.model.externalDevices.isEmpty, "A pre-stop discovery snapshot must not keep the editor disabled")
        XCTAssertNil(context.model.stopRequest(for: context.avd))
        XCTAssertNil(context.model.error)
        context.model.presentAVDConfiguration(context.avd)
        XCTAssertNotNil(context.model.editingConfiguration)
        XCTAssertEqual(try Data(contentsOf: context.configURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: context.dataURL), Data("phone-data".utf8))
        XCTAssertEqual(try Data(contentsOf: context.snapshotURL), Data("quick-boot-data".utf8))
        XCTAssertEqual(try context.fixture.launchCount(), 1)
    }

    func testLibraryStopCancelsStartupBeforeRuntimeExists() async throws {
        let context = try context()
        try context.fixture.mark("block-discovery")
        context.controller.start()
        try await eventually("Startup must reach the SDK discovery gate") { context.fixture.exists("discovery-blocked") }
        let discoveryPID = try context.fixture.pid("discovery-pid")
        XCTAssertEqual(context.controller.state, .starting)
        XCTAssertNil(context.controller.runtime)
        let request = try XCTUnwrap(context.model.stopRequest(for: context.avd))
        let stopping = Task { await context.model.stopDevice(request) }

        try await eventually("Library Stop must cancel the pending launch") { context.controller.state == .idle }
        XCTAssertEqual(Darwin.kill(discoveryPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        // stopDevice refreshes discovery after joining the cancelled launch.
        // Release only that fresh query; the original process is already gone.
        try context.fixture.remove("block-discovery")
        await stopping.value
        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertNil(context.controller.runtime)
        XCTAssertNil(context.model.stopRequest(for: context.avd))
        XCTAssertEqual(try context.fixture.launchCount(), 0)
        XCTAssertEqual(context.bridges.created.count, 0)
    }

    func testConfirmationCapturedBeforeRestartCannotStopReplacementRuntime() async throws {
        let context = try context()
        try await start(context)
        let request = try XCTUnwrap(context.model.stopRequest(for: context.avd))
        let originalRuntime = try XCTUnwrap(context.controller.runtime)
        await context.controller.restart()
        try await eventually("The replacement runtime must become ready") { context.controller.state == .running }
        let replacement = try XCTUnwrap(context.controller.runtime)
        XCTAssertNotEqual(replacement.id, originalRuntime.id)
        XCTAssertNotEqual(context.controller.lifecycleGeneration, request.generation)

        await context.model.stopDevice(request)

        XCTAssertTrue(context.model.error?.contains("restarted") == true)
        XCTAssertEqual(context.controller.state, .running)
        XCTAssertEqual(context.controller.runtime?.id, replacement.id)
        XCTAssertTrue(replacement.process.isRunning)
        XCTAssertEqual(try context.fixture.launchCount(), 2)
        let freshRequest = try XCTUnwrap(context.model.stopRequest(for: context.avd))
        await context.model.stopDevice(freshRequest)
        XCTAssertFalse(replacement.process.isRunning)
        XCTAssertEqual(context.controller.state, .idle)
    }

    func testExternallyManagedAndIdleDevicesNeverOfferOwnedStop() async throws {
        let context = try context()
        XCTAssertNil(context.model.stopRequest(for: context.avd), "An idle controller has nothing to stop")
        context.model.sessions.removeValue(forKey: context.avd.id)
        context.model.externalDevices = [ADBDevice(serial: "emulator-5998", state: "device", avdName: context.avd.name)]
        XCTAssertNil(context.model.librarySession(for: context.avd))
        XCTAssertNil(context.model.stopRequest(for: context.avd))

        let stale = DeviceStopRequest(avd: context.avd, session: context.controller,
                                      generation: context.controller.lifecycleGeneration)
        await context.model.stopDevice(stale)
        XCTAssertTrue(context.model.error?.contains("session changed") == true)
        XCTAssertEqual(context.model.externalDevices.map(\.serial), ["emulator-5998"])
        XCTAssertEqual(try context.fixture.launchCount(), 0)
        XCTAssertFalse(context.fixture.exists("runtime-terminated"))
    }

    func testSameNameInDifferentSDKOrConfigurationCannotStopOwnedRuntime() async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let request = try XCTUnwrap(context.model.stopRequest(for: context.avd))
        let selectedSDK = try XCTUnwrap(context.model.sdk)
        let otherSDK = try FixtureSDK()
        defer { try? FileManager.default.removeItem(at: otherSDK.root) }

        context.model.sdk = otherSDK.installation
        XCTAssertNil(context.model.librarySession(for: context.avd))
        XCTAssertNil(context.model.stopRequest(for: context.avd))
        await context.model.stopDevice(request)
        XCTAssertTrue(runtime.process.isRunning)
        XCTAssertTrue(context.model.error?.contains("session changed") == true)

        context.model.sdk = selectedSDK
        let otherDevice = AVD(name: context.avd.name, configURL: otherSDK.root.appendingPathComponent("different.avd/config.ini"))
        context.model.devices = [otherDevice]
        XCTAssertNil(context.model.librarySession(for: otherDevice), "An equal AVD name is not an equal phone configuration")
        XCTAssertNil(context.model.stopRequest(for: otherDevice))
        await context.model.stopDevice(request)
        XCTAssertTrue(runtime.process.isRunning)
        XCTAssertEqual(context.controller.state, .running)
        XCTAssertEqual(try context.fixture.launchCount(), 1)
    }

    func testReplacingControllerInvalidatesCapturedConfirmation() async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let request = try XCTUnwrap(context.model.stopRequest(for: context.avd))
        let replacement = SessionController(avd: context.avd, sdk: try XCTUnwrap(context.model.sdk),
            runtimeLedger: context.model.runtimeLedger, journalURL: context.fixture.root.appendingPathComponent("replacement.jsonl"),
            isQuitting: { context.model.isQuitting })
        context.model.sessions[context.avd.id] = replacement

        await context.model.stopDevice(request)

        XCTAssertTrue(context.model.error?.contains("session changed") == true)
        XCTAssertTrue(runtime.process.isRunning)
        XCTAssertEqual(replacement.state, .idle)
        XCTAssertNil(context.model.stopRequest(for: context.avd))
    }

    func testDuplicateStopAndQuitJoinCleanupWithoutStoppingAnotherOwnedRuntime() async throws {
        let context = try context(), other = try self.context()
        try await start(context)
        try await start(other)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let otherRuntime = try XCTUnwrap(other.controller.runtime)
        let bridge = try XCTUnwrap(context.bridges.created.first)
        let gate = bridge.holdStop()
        let request = try XCTUnwrap(context.model.stopRequest(for: context.avd))
        let stopping = Task { await context.model.stopDevice(request) }
        try await eventually("Stop must reach gated display cleanup") {
            context.controller.state == .stopping && bridge.stopCount == 1
        }
        XCTAssertNil(context.model.stopRequest(for: context.avd), "A stopping phone must not offer another confirmation")

        await context.model.stopDevice(request)
        XCTAssertEqual(bridge.stopCount, 1)
        XCTAssertTrue(runtime.process.isRunning)
        let quitting = Task { await context.model.shutdown() }
        try await eventually("Quit must join the stop already in progress") { context.model.isQuitting }
        XCTAssertEqual(bridge.stopCount, 1)
        XCTAssertTrue(otherRuntime.process.isRunning)
        await gate.open()
        await stopping.value
        await quitting.value

        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertFalse(runtime.process.isRunning)
        XCTAssertEqual(bridge.stopCount, 1)
        XCTAssertTrue(otherRuntime.process.isRunning)
        XCTAssertEqual(other.controller.state, .running)
        XCTAssertEqual(try other.fixture.launchCount(), 1)
    }

    func testFailedDisplayWithLivingGuestStillOffersLibraryStop() async throws {
        let context = try context(failDisplay: true)
        context.controller.start()
        try await eventually("Display failures must retain the running guest", timeout: 10) {
            context.controller.state == .failed && context.controller.runtime?.process.isRunning == true
        }
        XCTAssertFalse(context.controller.isActive)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let request = try XCTUnwrap(context.model.stopRequest(for: context.avd))
        await context.model.stopDevice(request)
        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertFalse(runtime.process.isRunning)
        XCTAssertNil(context.controller.runtime)
        XCTAssertEqual(try context.fixture.launchCount(), 1)
    }

    private func context(failDisplay: Bool = false) throws -> Context {
        let fixture = try FixtureSDK()
        let directory = fixture.root.appendingPathComponent("avd/Fixture_AVD.avd", isDirectory: true)
        let snapshots = directory.appendingPathComponent("snapshots/default_boot", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.ini")
        try Data("""
        avd.ini.displayname=Library Phone
        hw.ramSize=2048
        hw.cpu.ncore=4
        hw.lcd.width=1080
        hw.lcd.height=2400
        hw.lcd.density=420
        abi.type=arm64-v8a
        target=android-36
        \n
        """.utf8).write(to: configURL)
        try Data("path=\(directory.path)\ntarget=android-36\n".utf8)
            .write(to: directory.deletingLastPathComponent().appendingPathComponent("Fixture_AVD.ini"))
        try Data("managed".utf8).write(to: fixture.installation.root.appendingPathComponent(SDKLocator.managedMarkerName))
        let dataURL = directory.appendingPathComponent("userdata-qemu.img")
        let snapshotURL = snapshots.appendingPathComponent("snapshot.pb")
        try Data("phone-data".utf8).write(to: dataURL)
        try Data("quick-boot-data".utf8).write(to: snapshotURL)
        let sdk = try SDKLocator.validate(path: fixture.installation.root.path)
        let avd = AVDRepository.metadata(name: "Fixture_AVD", searchDirectories: [try XCTUnwrap(sdk.avdHome)])
        let model = AppModel(runtimeLedger: RuntimeLedger(url: fixture.root.appendingPathComponent("ledger.json")))
        model.sdkPath = sdk.root.path; model.sdk = sdk; model.devices = [avd]; model.stopOnQuit = true
        let bridges = LibraryBridgeFactory(failDisplay: failDisplay)
        let controller = SessionController(avd: avd, sdk: sdk,
            manager: EmulatorProcessManager(logDirectory: fixture.root.appendingPathComponent("logs")),
            runtimeLedger: model.runtimeLedger, journalURL: fixture.root.appendingPathComponent("journal.jsonl"),
            failureEvidenceStore: RuntimeFailureEvidenceStore(directoryURL: fixture.root.appendingPathComponent("failure-evidence")),
            isQuitting: { model.isQuitting }, bridgeFactory: { _, _ in bridges.make() })
        model.sessions[avd.id] = controller
        addTeardownBlock { @MainActor in
            await bridges.releaseStops()
            try? fixture.mark("shutdown")
            await controller.stop()
            await model.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        return Context(fixture: fixture, model: model, controller: controller, bridges: bridges,
                       avd: avd, configURL: configURL, dataURL: dataURL, snapshotURL: snapshotURL)
    }

    private func start(_ context: Context) async throws {
        context.controller.start()
        try await eventually("The fixture phone must become ready") { context.controller.state == .running }
    }

    private func eventually(_ message: String, timeout: TimeInterval = 6,
                            condition: @MainActor () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail(message, file: file, line: line)
                throw CocoaError(.executableRuntimeMismatch)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private struct Context {
        let fixture: FixtureSDK
        let model: AppModel
        let controller: SessionController
        let bridges: LibraryBridgeFactory
        let avd: AVD
        let configURL: URL
        let dataURL: URL
        let snapshotURL: URL
    }
}

@MainActor
private final class LibraryBridgeFactory {
    let failDisplay: Bool
    private(set) var created: [LibraryStopBridge] = []
    init(failDisplay: Bool) { self.failDisplay = failDisplay }
    func make() -> LibraryStopBridge {
        let bridge = LibraryStopBridge(failDisplay: failDisplay)
        created.append(bridge)
        return bridge
    }
    func releaseStops() async { for bridge in created { await bridge.releaseStop() } }
}

private final class LibraryStopBridge: DisplayBridge, @unchecked Sendable {
    private let failDisplay: Bool
    private let lock = NSLock()
    private var stopping: LibraryStopGate?
    private var stops = 0
    var stopCount: Int { lock.withLock { stops } }
    init(failDisplay: Bool) { self.failDisplay = failDisplay }
    func start(onFrame: @escaping @Sendable (DecodedFrame) -> Void,
               onDisconnect: @escaping @Sendable (String) -> Void) async throws {
        if failDisplay { throw CocoaError(.coderInvalidValue) }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw CocoaError(.coderInvalidValue) }
        let now = ProcessInfo.processInfo.systemUptime
        onFrame(DecodedFrame(pixelBuffer: buffer, presentationTime: .zero, receivedAt: now, decodedAt: now))
    }
    func stop() async {
        let gate = lock.withLock { stops += 1; return stopping }
        await gate?.wait()
    }
    func holdStop() -> LibraryStopGate {
        lock.withLock { let gate = LibraryStopGate(); stopping = gate; return gate }
    }
    func releaseStop() async { await lock.withLock { stopping }?.open() }
    func send(_ input: BridgeInput) { }
    func readClipboard() async throws -> String { throw CocoaError(.featureUnsupported) }
}

private actor LibraryStopGate {
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

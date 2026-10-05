import XCTest
import CoreMedia
import CoreVideo
@testable import AndroidSimulator
@testable import SimulatorKit

/// Uses temporary SDK scripts and a one-pixel display, never an installed SDK
/// or a native device window. Rejected actions must preserve the exact runtime.
@MainActor
final class DeviceSessionIdentityTests: XCTestCase {
    func testOtherSDKCannotOpenColdBootOrWipeSameNamedRunningPhone() async throws {
        try await assertLibraryActionsPreserveOriginalSession(switchSDK: true)
    }

    func testChangedConfigurationCannotOpenColdBootOrWipeSameNamedRunningPhone() async throws {
        try await assertLibraryActionsPreserveOriginalSession(switchSDK: false)
    }

    func testTerminalActionsRejectSameNameInAnotherSDK() async throws {
        try await assertTerminalActionsPreserveOriginalSession(switchSDK: true)
    }

    func testTerminalActionsRejectSameNameWithAnotherConfiguration() async throws {
        try await assertTerminalActionsPreserveOriginalSession(switchSDK: false)
    }

    func testStartupWithoutRuntimeAlsoRejectsAnotherPhoneWithSameName() throws {
        let context = try context()
        context.controller.start()
        XCTAssertEqual(context.controller.state, .starting)
        XCTAssertNil(context.controller.runtime)
        let generation = context.controller.lifecycleGeneration
        try selectReplacement(context, switchSDK: true)

        XCTAssertThrowsError(try context.model.prepareSessionForLaunch(context.replacement))
        context.model.launch(context.replacement, wipeData: true)

        XCTAssertTrue(context.model.sessions[context.original.id] === context.controller)
        XCTAssertEqual(context.controller.lifecycleGeneration, generation)
        XCTAssertEqual(context.controller.state, .starting)
        XCTAssertEqual(try context.fixture.launchCount(), 0)
        XCTAssertEqual(try context.otherFixture.launchCount(), 0)
    }

    func testIdleMismatchesRetireBeforeAReplacementLaunch() throws {
        for switchSDK in [true, false] {
            let context = try context()
            try selectReplacement(context, switchSDK: switchSDK)

            try context.model.prepareSessionForLaunch(context.replacement)

            XCTAssertNil(context.model.sessions[context.original.id])
            XCTAssertEqual(context.controller.state, .idle)
            XCTAssertEqual(try context.fixture.launchCount(), 0)
            XCTAssertEqual(try context.otherFixture.launchCount(), 0)
            try assertPhoneDataPreserved(context)
        }
    }

    func testStaleLibraryRequestCannotReplaceSessionForTheNewSelection() throws {
        let context = try context()
        try selectReplacement(context, switchSDK: false)

        XCTAssertThrowsError(try context.model.prepareSessionForLaunch(context.original))

        XCTAssertTrue(context.model.sessions[context.original.id] === context.controller)
        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertEqual(try context.fixture.launchCount(), 0)
    }

    func testMatchingSessionRetainsOwnershipAndTerminalStopStillWorks() async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)

        try context.model.prepareSessionForLaunch(context.original)
        XCTAssertTrue(context.model.librarySession(for: context.original) === context.controller)
        let listed = await handler(context).execute(SimulatorCommandRequest(action: .list))
        XCTAssertTrue(listed.success)
        XCTAssertEqual(listed.devices.first?.isOwned, true)
        XCTAssertEqual(listed.devices.first?.serial, runtime.serial)
        let stopped = await handler(context).execute(SimulatorCommandRequest(action: .stop, device: context.original.name))

        XCTAssertTrue(stopped.success, stopped.message)
        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertFalse(runtime.process.isRunning)
        XCTAssertEqual(try context.fixture.launchCount(), 1)
        try assertPhoneDataPreserved(context)
    }

    private func assertLibraryActionsPreserveOriginalSession(switchSDK: Bool) async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let generation = context.controller.lifecycleGeneration
        try selectReplacement(context, switchSDK: switchSDK)

        for options in [(coldBoot: false, wipeData: false), (coldBoot: true, wipeData: false), (coldBoot: false, wipeData: true)] {
            context.model.error = nil
            context.model.launch(context.replacement, coldBoot: options.coldBoot, wipeData: options.wipeData)
            XCTAssertTrue(context.model.error?.contains("different phone") == true)
        }
        // Give any incorrectly scheduled restart task a chance to change its
        // generation before asserting that the original guest was untouched.
        try await Task.sleep(nanoseconds: 50_000_000)
        try assertOriginalSessionPreserved(context, runtime: runtime, generation: generation)
    }

    private func assertTerminalActionsPreserveOriginalSession(switchSDK: Bool) async throws {
        let context = try context()
        try await start(context)
        let runtime = try XCTUnwrap(context.controller.runtime)
        let generation = context.controller.lifecycleGeneration
        try selectReplacement(context, switchSDK: switchSDK)
        let commands = handler(context)
        let actions: [(SimulatorCommandAction, String?)] = [
            (.boot, nil), (.open, nil), (.stop, nil),
            (.install, context.fixture.root.appendingPathComponent("unused.apk").path),
            (.openURL, "exp://127.0.0.1:8081")
        ]
        for (action, argument) in actions {
            let result = await commands.execute(SimulatorCommandRequest(action: action, device: context.original.name, argument: argument))
            XCTAssertFalse(result.success, "\(action.rawValue) must reject the mismatched controller")
            XCTAssertEqual(result.errorCode, "session_mismatch", result.message)
        }
        let listed = await commands.execute(SimulatorCommandRequest(action: .list))
        XCTAssertTrue(listed.success, "Read-only discovery remains available")
        XCTAssertEqual(listed.devices.first?.isOwned, false, "The other phone must not inherit the old controller's ownership")
        try assertOriginalSessionPreserved(context, runtime: runtime, generation: generation)
    }

    private func assertOriginalSessionPreserved(_ context: Context, runtime: RunningEmulator, generation: Int) throws {
        XCTAssertTrue(context.model.sessions[context.original.id] === context.controller)
        XCTAssertEqual(context.controller.state, .running)
        XCTAssertEqual(context.controller.runtime?.id, runtime.id)
        XCTAssertEqual(context.controller.lifecycleGeneration, generation)
        XCTAssertTrue(runtime.process.isRunning)
        XCTAssertFalse(context.fixture.exists("runtime-terminated"))
        XCTAssertEqual(try context.fixture.launchCount(), 1)
        XCTAssertEqual(try context.otherFixture.launchCount(), 0)
        try assertPhoneDataPreserved(context)
    }

    private func assertPhoneDataPreserved(_ context: Context) throws {
        for avd in [context.original, context.replacement] {
            let config = try XCTUnwrap(avd.configURL)
            XCTAssertEqual(try Data(contentsOf: config), Data(Self.configuration.utf8))
            XCTAssertEqual(try Data(contentsOf: config.deletingLastPathComponent().appendingPathComponent("userdata-qemu.img")), Data("phone-data".utf8))
        }
    }

    private func selectReplacement(_ context: Context, switchSDK: Bool) throws {
        if switchSDK {
            context.model.sdk = context.otherSDK
            context.model.sdkPath = context.otherSDK.root.path
        } else {
            // An index can be changed outside DroidDock while its old session
            // survives. Fresh terminal discovery must see the replacement path.
            let index = try XCTUnwrap(context.original.indexURL)
            let directory = try XCTUnwrap(context.replacement.configURL).deletingLastPathComponent()
            try Data("path=\(directory.path)\ntarget=android-36\n".utf8).write(to: index)
        }
        context.model.devices = [context.replacement]
    }

    private func handler(_ context: Context) -> TerminalCommandHandler {
        TerminalCommandHandler(model: context.model,
            store: SimulatorCommandStore(directory: context.fixture.root.appendingPathComponent("mailbox")))
    }

    private func context() throws -> Context {
        let fixture = try FixtureSDK(), otherFixture = try FixtureSDK()
        let (sdk, original) = try phone(in: fixture)
        let (otherSDK, replacement) = try phone(in: otherFixture)
        let model = AppModel(runtimeLedger: RuntimeLedger(url: fixture.root.appendingPathComponent("ledger.json")))
        model.sdkPath = sdk.root.path; model.sdk = sdk; model.devices = [original]; model.stopOnQuit = true
        let controller = SessionController(avd: original, sdk: sdk,
            manager: EmulatorProcessManager(logDirectory: fixture.root.appendingPathComponent("logs")),
            runtimeLedger: model.runtimeLedger, journalURL: fixture.root.appendingPathComponent("journal.jsonl"),
            failureEvidenceStore: RuntimeFailureEvidenceStore(directoryURL: fixture.root.appendingPathComponent("failure-evidence")),
            isQuitting: { model.isQuitting }, bridgeFactory: { _, _ in IdentityFixtureBridge() })
        model.sessions[original.id] = controller
        addTeardownBlock { @MainActor in
            try? fixture.mark("shutdown"); try? otherFixture.mark("shutdown")
            await controller.stop()
            await model.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: otherFixture.root)
        }
        return Context(fixture: fixture, otherFixture: otherFixture, model: model, controller: controller,
                       original: original, replacement: replacement, otherSDK: otherSDK)
    }

    private func phone(in fixture: FixtureSDK) throws -> (SDKInstallation, AVD) {
        let directory = fixture.root.appendingPathComponent("avd/Fixture_AVD.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.configuration.utf8).write(to: directory.appendingPathComponent("config.ini"))
        try Data("phone-data".utf8).write(to: directory.appendingPathComponent("userdata-qemu.img"))
        try Data("path=\(directory.path)\ntarget=android-36\n".utf8)
            .write(to: directory.deletingLastPathComponent().appendingPathComponent("Fixture_AVD.ini"))
        try Data("managed".utf8).write(to: fixture.installation.root.appendingPathComponent(SDKLocator.managedMarkerName))
        let sdk = try SDKLocator.validate(path: fixture.installation.root.path)
        let avd = AVDRepository.metadata(name: "Fixture_AVD", searchDirectories: [try XCTUnwrap(sdk.avdHome)])
        return (sdk, avd)
    }

    private func start(_ context: Context) async throws {
        context.controller.start()
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while context.controller.state != .running {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Fixture must become ready: \(context.controller.error ?? context.controller.status)")
                throw CocoaError(.executableRuntimeMismatch)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static let configuration = "avd.ini.displayname=Fixture Phone\nhw.ramSize=2048\nabi.type=arm64-v8a\ntarget=android-36\n"

    private struct Context {
        let fixture: FixtureSDK
        let otherFixture: FixtureSDK
        let model: AppModel
        let controller: SessionController
        let original: AVD
        let replacement: AVD
        let otherSDK: SDKInstallation
    }
}

private final class IdentityFixtureBridge: DisplayBridge, Sendable {
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

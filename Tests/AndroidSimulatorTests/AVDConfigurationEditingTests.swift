import XCTest
@testable import AndroidSimulator
@testable import SimulatorKit

@MainActor
final class AVDConfigurationEditingTests: XCTestCase {
    func testSaveRefreshesMetadataAndRetiresIdleSessionWithoutChangingPhoneData() async throws {
        var queries = 0
        let context = try context(lookup: { _ in queries += 1; return [] })
        let model = context.model
        let session = idleSession(context)
        model.sessions[context.avd.id] = session
        model.presentAVDConfiguration(context.avd)
        let request = try XCTUnwrap(model.editingConfiguration)
        var configuration = request.document.configuration
        configuration.displayName = "Updated Phone"
        configuration.memoryMB = 3072
        configuration.width = 1440
        configuration.height = 2560

        await model.saveAVDConfiguration(configuration)

        XCTAssertEqual(queries, 1)
        XCTAssertNil(model.configurationError)
        XCTAssertNil(model.editingConfiguration)
        XCTAssertFalse(model.isSavingConfiguration)
        XCTAssertNil(model.sessions[context.avd.id], "An immutable session must not keep pre-edit metadata")
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(model.devices.first?.displayName, "Updated Phone")
        XCTAssertEqual(model.devices.first?.memoryMB, 3072)
        XCTAssertEqual(model.devices.first?.resolution, "1440 × 2560")
        XCTAssertEqual(try Data(contentsOf: context.dataURL), Data("phone-data".utf8))
        XCTAssertEqual(try context.fixture.launchCount(), 0)
    }

    func testPendingLaunchAndCachedExternalRuntimePreventOpeningEditor() throws {
        let context = try context()
        let model = context.model
        model.pendingLaunch = DeviceLaunchRequest(avd: context.avd, coldBoot: false, wipeData: false, warning: "Fixture")
        model.presentAVDConfiguration(context.avd)
        XCTAssertNil(model.editingConfiguration)
        XCTAssertTrue(model.error?.contains("pending start") == true)
        model.pendingLaunch = nil
        model.externalDevices = [ADBDevice(serial: "emulator-5554", state: "device", avdName: context.avd.name)]
        model.presentAVDConfiguration(context.avd)
        XCTAssertNil(model.editingConfiguration)
        XCTAssertTrue(model.error?.contains("running") == true)
    }

    func testAppAndTerminalBootAreBlockedWhileEditorRemainsOpen() async throws {
        let context = try context()
        let model = context.model
        model.presentAVDConfiguration(context.avd)
        XCTAssertNotNil(model.editingConfiguration)
        model.launch(context.avd)
        XCTAssertTrue(model.error?.contains("Finish editing") == true)
        XCTAssertTrue(model.sessions.isEmpty)
        let handler = TerminalCommandHandler(model: model,
            store: SimulatorCommandStore(directory: context.fixture.root.appendingPathComponent("mailbox")))
        let result = await handler.execute(SimulatorCommandRequest(action: .boot, device: context.avd.name))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, "device_busy")
        let listed = await handler.execute(SimulatorCommandRequest(action: .list))
        XCTAssertTrue(listed.success, "Read-only terminal commands remain available while editing")
        XCTAssertNotNil(model.editingConfiguration)
        XCTAssertEqual(try context.fixture.launchCount(), 0)
    }

    func testStartingLocalSessionPreventsEditingAndDeletion() async throws {
        let context = try context()
        let original = try Data(contentsOf: context.configURL)
        let session = idleSession(context)
        context.model.sessions[context.avd.id] = session
        session.start()
        XCTAssertEqual(session.state, .starting)
        context.model.presentAVDConfiguration(context.avd)
        XCTAssertNil(context.model.editingConfiguration)
        XCTAssertTrue(context.model.error?.contains("Stop") == true)
        await context.model.deleteAVD(context.avd)
        XCTAssertTrue(context.model.error?.contains("Stop") == true)
        XCTAssertEqual(try Data(contentsOf: context.configURL), original)
        await session.stop()
        XCTAssertEqual(session.state, .idle)
    }

    func testFreshExternalAndUnidentifiedEmulatorsRejectSavingUnchangedBytes() async throws {
        for device in [ADBDevice(serial: "emulator-5554", state: "device", avdName: "Fixture_AVD"),
                       ADBDevice(serial: "emulator-5556", state: "offline")] {
            let context = try context(lookup: { _ in [device] })
            let original = try Data(contentsOf: context.configURL)
            context.model.presentAVDConfiguration(context.avd)
            var configuration = try XCTUnwrap(context.model.editingConfiguration).document.configuration
            configuration.memoryMB = 4096
            await context.model.saveAVDConfiguration(configuration)
            XCTAssertNotNil(context.model.configurationError)
            XCTAssertNotNil(context.model.editingConfiguration)
            XCTAssertEqual(try Data(contentsOf: context.configURL), original)
        }
    }

    func testFailedADBQueryPreventsSaveAndDelete() async throws {
        let context = try context(lookup: { _ in throw AppFailure("ADB could not be queried") })
        let original = try Data(contentsOf: context.configURL)
        context.model.presentAVDConfiguration(context.avd)
        var configuration = try XCTUnwrap(context.model.editingConfiguration).document.configuration
        configuration.memoryMB = 4096
        await context.model.saveAVDConfiguration(configuration)
        XCTAssertEqual(context.model.configurationError, "ADB could not be queried")
        context.model.editingConfiguration = nil
        await context.model.deleteAVD(context.avd)
        XCTAssertEqual(context.model.error, "ADB could not be queried")
        XCTAssertEqual(try Data(contentsOf: context.configURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(context.avd.indexURL).path))
        XCTAssertFalse(context.model.isDeletingDevice)
    }

    func testSDKChangeDuringQueryRejectsSaveAndKeepsEditorOpen() async throws {
        let gate = QueryGate()
        let context = try context(lookup: { _ in try await gate.wait() })
        let original = try Data(contentsOf: context.configURL)
        context.model.presentAVDConfiguration(context.avd)
        var configuration = try XCTUnwrap(context.model.editingConfiguration).document.configuration
        configuration.memoryMB = 4096
        let save = Task { await context.model.saveAVDConfiguration(configuration) }
        try await eventually { gate.started }
        XCTAssertTrue(context.model.isSavingConfiguration)
        context.model.sdkPath = context.fixture.root.appendingPathComponent("another-sdk").path
        gate.released = true
        await save.value
        XCTAssertTrue(context.model.configurationError?.contains("SDK or phone changed") == true)
        XCTAssertNotNil(context.model.editingConfiguration)
        XCTAssertEqual(try Data(contentsOf: context.configURL), original)
    }

    func testPendingLaunchAddedDuringQueryPreventsWrite() async throws {
        let gate = QueryGate()
        let context = try context(lookup: { _ in try await gate.wait() })
        let original = try Data(contentsOf: context.configURL)
        context.model.presentAVDConfiguration(context.avd)
        var configuration = try XCTUnwrap(context.model.editingConfiguration).document.configuration
        configuration.displayName = "Rejected"
        let save = Task { await context.model.saveAVDConfiguration(configuration) }
        try await eventually { gate.started }
        context.model.pendingLaunch = DeviceLaunchRequest(avd: context.avd, coldBoot: false, wipeData: false, warning: "Fixture")
        gate.released = true
        await save.value
        XCTAssertTrue(context.model.configurationError?.contains("pending start") == true)
        XCTAssertEqual(try Data(contentsOf: context.configURL), original)
    }

    func testLocalStartDuringSafetyQueryIsRecheckedBeforeSaving() async throws {
        let gate = QueryGate()
        let context = try context(lookup: { _ in try await gate.wait() })
        let original = try Data(contentsOf: context.configURL)
        context.model.presentAVDConfiguration(context.avd)
        var configuration = try XCTUnwrap(context.model.editingConfiguration).document.configuration
        configuration.memoryMB = 4096
        let save = Task { await context.model.saveAVDConfiguration(configuration) }
        try await eventually { gate.started }
        let session = idleSession(context)
        context.model.sessions[context.avd.id] = session
        session.start()
        gate.released = true
        await save.value
        XCTAssertTrue(context.model.configurationError?.contains("Stop") == true)
        XCTAssertEqual(try Data(contentsOf: context.configURL), original)
        await session.stop()
    }

    func testDeletingLastPhonePreservesSDKAndMakesSetupAvailableAgain() async throws {
        let context = try context()
        context.model.sessions[context.avd.id] = idleSession(context)
        context.model.selectedDevice = context.avd.id
        XCTAssertTrue(context.model.isManagedAndroidReady)

        await context.model.deleteAVD(context.avd)

        XCTAssertNil(context.model.error)
        XCTAssertFalse(context.model.isDeletingDevice)
        XCTAssertTrue(context.model.devices.isEmpty)
        XCTAssertFalse(context.model.isManagedAndroidReady)
        XCTAssertNil(context.model.selectedDevice)
        XCTAssertNil(context.model.sessions[context.avd.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(context.avd.indexURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.fixture.installation.emulator.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.fixture.installation.adb.path))
        let trashedData = context.fixture.root.appendingPathComponent("fixture-trash/Fixture_AVD.avd/userdata-qemu.img")
        XCTAssertEqual(try Data(contentsOf: trashedData), Data("phone-data".utf8))
        XCTAssertEqual(try context.fixture.launchCount(), 0)
    }

    func testDeleteBlocksAppLaunchAndRejectsExternalRuntimeAppearingDuringQuery() async throws {
        let gate = QueryGate()
        let context = try context(lookup: { _ in try await gate.wait() })
        let deletion = Task { await context.model.deleteAVD(context.avd) }
        try await eventually { gate.started }
        context.model.launch(context.avd)
        XCTAssertTrue(context.model.sessions.isEmpty)
        gate.devices = [ADBDevice(serial: "emulator-5554", state: "device", avdName: context.avd.name)]
        gate.released = true
        await deletion.value
        XCTAssertTrue(context.model.error?.contains("running") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.configURL.path))
        XCTAssertTrue(context.model.isManagedAndroidReady)
        XCTAssertEqual(try context.fixture.launchCount(), 0)
    }

    func testShutdownCancelsSafetyQueryBeforeConfigurationCanBeWritten() async throws {
        let gate = QueryGate()
        let context = try context(lookup: { _ in try await gate.wait() })
        let original = try Data(contentsOf: context.configURL)
        context.model.presentAVDConfiguration(context.avd)
        var configuration = try XCTUnwrap(context.model.editingConfiguration).document.configuration
        configuration.displayName = "Never saved"
        let save = Task { await context.model.saveAVDConfiguration(configuration) }
        try await eventually { gate.started }
        await context.model.shutdown()
        await save.value
        XCTAssertFalse(context.model.isSavingConfiguration)
        XCTAssertEqual(try Data(contentsOf: context.configURL), original)
    }

    private func context(lookup: @escaping @MainActor (SDKInstallation) async throws -> [ADBDevice] = { _ in [] }) throws -> Context {
        let fixture = try FixtureSDK()
        let avdHome = fixture.root.appendingPathComponent("avd", isDirectory: true)
        let directory = avdHome.appendingPathComponent("Fixture_AVD.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.ini")
        try Data("""
        avd.ini.displayname=Original Phone
        hw.ramSize=2048
        hw.cpu.ncore=4
        hw.lcd.width=1080
        hw.lcd.height=2400
        hw.lcd.density=420
        abi.type=arm64-v8a
        target=android-36
        \n
        """.utf8).write(to: configURL)
        try Data("path=\(directory.path)\ntarget=android-36\n".utf8).write(to: avdHome.appendingPathComponent("Fixture_AVD.ini"))
        try Data("managed".utf8).write(to: fixture.installation.root.appendingPathComponent(".droiddock-managed"))
        let dataURL = directory.appendingPathComponent("userdata-qemu.img")
        try Data("phone-data".utf8).write(to: dataURL)
        let sdk = try SDKLocator.validate(path: fixture.installation.root.path)
        let avd = AVDRepository.metadata(name: "Fixture_AVD", searchDirectories: [try XCTUnwrap(sdk.avdHome)])
        let model = AppModel(runtimeLedger: RuntimeLedger(url: fixture.root.appendingPathComponent("ledger.json")),
            configurationDeviceLookup: lookup, configurationDeletion: { plan in
                let trash = fixture.root.appendingPathComponent("fixture-trash", isDirectory: true)
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                try AVDDeletionStore.delete(plan, trash: { url in
                    let destination = trash.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: destination)
                    return destination
                })
                try Data().write(to: fixture.root.appendingPathComponent("avd-name"))
            })
        model.sdkPath = sdk.root.path; model.sdk = sdk; model.devices = [avd]
        addTeardownBlock { @MainActor in
            try? fixture.mark("shutdown")
            await model.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        return Context(fixture: fixture, model: model, avd: avd, configURL: configURL, dataURL: dataURL)
    }

    private func idleSession(_ context: Context) -> SessionController {
        SessionController(avd: context.avd, sdk: context.model.sdk!, runtimeLedger: context.model.runtimeLedger,
                          journalURL: context.fixture.root.appendingPathComponent("session.jsonl"),
                          isQuitting: { context.model.isQuitting })
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw AppFailure("Configuration safety query did not start") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private struct Context {
        let fixture: FixtureSDK
        let model: AppModel
        let avd: AVD
        let configURL: URL
        let dataURL: URL
    }

    @MainActor private final class QueryGate {
        var started = false
        var released = false
        var devices: [ADBDevice] = []
        func wait() async throws -> [ADBDevice] {
            started = true
            while !released { try await Task.sleep(nanoseconds: 1_000_000) }
            return devices
        }
    }
}

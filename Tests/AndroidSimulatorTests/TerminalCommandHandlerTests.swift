import XCTest
import Darwin
@testable import AndroidSimulator
import SimulatorKit

/// Exercises the production URL receiver and app model against ordinary SDK
/// fixture children. No NSApplication, native window or Android VM is started.
@MainActor
final class TerminalCommandHandlerTests: XCTestCase {
    func testListAndStatusReportDiscoveredDevicesWithoutStartingThem() async throws {
        let context = try context()
        let request = SimulatorCommandRequest(action: .list)
        let listed = await context.handler.execute(request)
        XCTAssertTrue(listed.success, listed.message)
        XCTAssertEqual(listed.id, request.id)
        XCTAssertNil(listed.errorCode)
        let device = try XCTUnwrap(listed.devices.first)
        XCTAssertEqual(listed.devices.count, 1)
        XCTAssertEqual(device.id, "Fixture_AVD")
        XCTAssertEqual(device.name, "Fixture AVD")
        XCTAssertEqual(device.state, "idle")
        XCTAssertFalse(device.isOwned)
        XCTAssertNil(device.serial)
        XCTAssertNil(device.pid)
        XCTAssertEqual(device.sdkPath, context.fixture.installation.root.standardizedFileURL.resolvingSymlinksInPath().path)

        for selected in [nil, Optional("Fixture_AVD"), Optional("Fixture AVD")] {
            let status = await context.handler.execute(SimulatorCommandRequest(action: .status, device: selected))
            XCTAssertTrue(status.success, status.message)
            XCTAssertEqual(status.devices, listed.devices)
        }
        XCTAssertTrue(context.model.sessions.isEmpty)
        XCTAssertEqual(try context.fixture.launchCount(), 0)
    }

    func testUnknownDeviceBootIsRejectedBeforeCreatingAWindowOrRuntime() async throws {
        let context = try context()
        let result = await context.handler.execute(SimulatorCommandRequest(action: .boot, device: "Missing_Device"))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, "device_not_found")
        XCTAssertTrue(result.message.contains("droiddock list"))
        XCTAssertTrue(result.devices.isEmpty)
        XCTAssertTrue(context.model.sessions.isEmpty)
        XCTAssertNil(context.model.pendingLaunch)
        XCTAssertEqual(try context.fixture.launchCount(), 0)
    }

    func testStopRequiresAppOwnershipAndDoesNotStartAnIdleDevice() async throws {
        let context = try context()
        let result = await context.handler.execute(SimulatorCommandRequest(action: .stop, device: "Fixture_AVD"))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, "not_owned")
        XCTAssertTrue(result.message.contains("not running in this app"))
        XCTAssertTrue(context.model.sessions.isEmpty)
        XCTAssertEqual(try context.fixture.launchCount(), 0)
        XCTAssertFalse(context.fixture.exists("runtime-terminated"))
    }

    func testExpiredBootNeverBeginsSDKDiscoveryOrDeviceLaunch() async throws {
        let context = try context()
        try context.fixture.mark("block-list")
        let request = SimulatorCommandRequest(action: .boot, device: "Fixture_AVD", timeout: 1,
                                              createdAt: Date().addingTimeInterval(-10))
        let started = ProcessInfo.processInfo.systemUptime
        let result = await context.handler.execute(request)
        XCTAssertFalse(result.success)
        XCTAssertTrue(["expired", "timeout"].contains(result.errorCode ?? ""))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertFalse(context.fixture.exists("list-blocked"))
        XCTAssertFalse(context.model.loading)
        XCTAssertTrue(context.model.sessions.isEmpty)
        XCTAssertEqual(try context.fixture.launchCount(), 0)
    }

    func testDeadlineCancelsBlockedSDKQueryAndCannotLaunchWhenGateLaterOpens() async throws {
        let context = try context()
        await context.model.refresh()
        let previousSDK = context.model.sdk, previousDevices = context.model.devices
        let previousExternal = [ADBDevice(serial: "emulator-5998", state: "device", avdName: "External_Fixture")]
        context.model.externalDevices = previousExternal
        try context.fixture.mark("block-discovery")
        let request = SimulatorCommandRequest(action: .boot, device: "Fixture_AVD", timeout: 1)
        let started = ProcessInfo.processInfo.systemUptime
        let operation = Task { await context.handler.execute(request) }
        addTeardownBlock { @MainActor in
            operation.cancel()
            try? context.fixture.mark("shutdown")
            _ = await operation.value
        }
        try await eventually("Terminal boot must enter the blocked ADB discovery fixture") {
            context.fixture.exists("discovery-blocked")
        }
        let discoveryPID = try context.fixture.pid("discovery-pid")
        let result = await operation.value
        XCTAssertFalse(result.success)
        XCTAssertTrue(["expired", "timeout"].contains(result.errorCode ?? ""), result.message)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5,
                          "A one-second request must cancel the query, including its bounded TERM-to-KILL cleanup")
        XCTAssertEqual(Darwin.kill(discoveryPID, 0), -1)
        XCTAssertEqual(errno, ESRCH, "The cancelled SDK child must be reaped before returning")
        XCTAssertFalse(context.model.loading)
        XCTAssertEqual(context.model.sdk, previousSDK)
        XCTAssertEqual(context.model.devices, previousDevices)
        XCTAssertEqual(context.model.externalDevices, previousExternal,
                       "A cancelled discovery must not erase existing external-device advisories")
        XCTAssertTrue(context.model.sessions.isEmpty)
        XCTAssertEqual(try context.fixture.launchCount(), 0)

        // Opening the former gate and successfully making another request must
        // not resume the expired boot or retain a pending launch intention.
        try context.fixture.remove("block-discovery")
        let next = await context.handler.execute(SimulatorCommandRequest(action: .list))
        XCTAssertTrue(next.success, next.message)
        XCTAssertEqual(next.devices.map(\.id), ["Fixture_AVD"])
        XCTAssertTrue(context.model.sessions.isEmpty)
        XCTAssertNil(context.model.pendingLaunch)
        XCTAssertEqual(try context.fixture.launchCount(), 0)
    }

    func testURLReceiverRepliesThroughMailboxAndIgnoresUnknownIDs() async throws {
        let context = try context()
        let request = SimulatorCommandRequest(action: .status, device: "Fixture_AVD")
        try context.store.createRequest(request)
        context.handler.receive([SimulatorCommandStore.commandURL(id: UUID()),
                                 SimulatorCommandStore.commandURL(id: request.id),
                                 SimulatorCommandStore.commandURL(id: request.id)])
        try await eventually("The URL receiver should deliver the matching reply") {
            (try? context.store.readResponse(id: request.id)) != nil
        }
        let result = try XCTUnwrap(context.store.readResponse(id: request.id))
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(result.id, request.id)
        XCTAssertEqual(result.devices.map(\.id), ["Fixture_AVD"])
        XCTAssertEqual(try context.fixture.launchCount(), 0)
        try context.store.remove(id: request.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.store.directory.path), [])
    }

    private func context() throws -> (fixture: FixtureSDK, model: AppModel, handler: TerminalCommandHandler, store: SimulatorCommandStore) {
        let fixture = try FixtureSDK()
        let model = AppModel(runtimeLedger: RuntimeLedger(url: fixture.root.appendingPathComponent("ledger.json")))
        model.sdkPath = fixture.installation.root.path
        let store = SimulatorCommandStore(directory: fixture.root.appendingPathComponent("Commands", isDirectory: true))
        let handler = TerminalCommandHandler(model: model, store: store)
        addTeardownBlock { @MainActor in
            try? fixture.mark("shutdown")
            await model.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        return (fixture, model, handler, store)
    }

    private func eventually(_ message: String, condition: @MainActor () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail(message, file: file, line: line)
                throw CocoaError(.executableRuntimeMismatch)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

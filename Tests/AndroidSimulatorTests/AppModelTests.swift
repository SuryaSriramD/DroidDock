import XCTest
import Combine
@testable import AndroidSimulator
import SimulatorKit

@MainActor
final class AppModelTests: XCTestCase {
    func testManagedSetupReadinessFollowsDiscoveredRuntimeAndDevices() async throws {
        let fixture = try FixtureSDK(avdName: ManagedAndroidRuntime.deviceName)
        let marker = fixture.installation.root.appendingPathComponent(".droiddock-managed")
        let deviceList = fixture.root.appendingPathComponent("avd-name")
        try Data("1".utf8).write(to: marker)
        let model = AppModel(runtimeLedger: RuntimeLedger(url: fixture.root.appendingPathComponent("ledger.json")))
        model.sdkPath = fixture.installation.root.path
        addTeardownBlock { @MainActor in
            await model.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        XCTAssertFalse(model.isManagedAndroidReady)
        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.isManagedAndroidReady, "Discovery must recognize completed setup after an app relaunch")
        model.selectedDevice = nil
        XCTAssertTrue(model.isManagedAndroidReady, "Clearing selection must not restore setup prompts")
        model.presentAndroidSetup()
        XCTAssertFalse(model.showingAndroidSetup, "An installed managed runtime and phone must not reopen first-use setup")

        try Data().write(to: deviceList)
        await model.refresh()
        XCTAssertFalse(model.isManagedAndroidReady, "Setup must be available if the managed phone is removed")
        try Data(ManagedAndroidRuntime.deviceName.utf8).write(to: deviceList)
        await model.refresh()
        XCTAssertTrue(model.isManagedAndroidReady)

        try FileManager.default.removeItem(at: marker)
        await model.refresh()
        XCTAssertFalse(model.devices.isEmpty)
        XCTAssertFalse(model.isManagedAndroidReady, "An external SDK must retain the option to install DroidDock's runtime")

        model.sdkPath = fixture.root.appendingPathComponent("missing-sdk").path
        await model.refresh()
        XCTAssertNil(model.sdk)
        XCTAssertFalse(model.isManagedAndroidReady)
        XCTAssertEqual(try fixture.launchCount(), 0)
    }

    func testSDKChangeDuringRefreshPublishesOnlyTheLatestSDKAndDevices() async throws {
        let oldSDK = try FixtureSDK(avdName: "Old_Fixture_AVD")
        let newSDK = try FixtureSDK(avdName: "New_Fixture_AVD")
        let model = AppModel(runtimeLedger: RuntimeLedger(url: oldSDK.root.appendingPathComponent("ledger.json")))
        model.sdkPath = oldSDK.installation.root.path
        try oldSDK.mark("block-list")
        var publishedSDKs: [String] = []
        var publishedDevices: [[String]] = []
        let sdkSubscription = model.$sdk.compactMap { $0?.root.path }.sink { publishedSDKs.append($0) }
        let deviceSubscription = model.$devices.dropFirst().sink { publishedDevices.append($0.map(\.name)) }
        let refresh = Task { await model.refresh() }
        addTeardownBlock { @MainActor in
            try? oldSDK.mark("shutdown"); try? newSDK.mark("shutdown")
            await refresh.value
            await model.shutdown()
            try? FileManager.default.removeItem(at: oldSDK.root)
            try? FileManager.default.removeItem(at: newSDK.root)
            sdkSubscription.cancel(); deviceSubscription.cancel()
        }

        try await eventually("Old SDK discovery must reach the deterministic gate") { oldSDK.exists("list-blocked") }
        model.sdkPath = newSDK.installation.root.path
        await model.refresh() // Records the new request while the first one awaits its process.
        XCTAssertTrue(model.loading)
        model.presentAndroidSetup()
        XCTAssertFalse(model.showingAndroidSetup, "Setup must wait for discovery to determine whether Android is already installed")
        XCTAssertNil(model.sdk)
        XCTAssertTrue(model.devices.isEmpty)
        try oldSDK.remove("block-list")
        try await eventually("Queued refresh should complete using the new SDK") { !model.loading }
        await refresh.value

        let expectedRoot = newSDK.installation.root.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(model.sdk?.root.path, expectedRoot)
        XCTAssertEqual(model.devices.map(\.name), ["New_Fixture_AVD"])
        XCTAssertEqual(publishedSDKs, [expectedRoot], "Observers must never receive the old SDK after the preference changes")
        XCTAssertEqual(publishedDevices, [["New_Fixture_AVD"]], "Stale discovery must not briefly replace the library")
        XCTAssertNil(model.error)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(try oldSDK.launchCount(), 0)
        XCTAssertEqual(try newSDK.launchCount(), 0)
    }

    private func eventually(_ message: String, condition: @MainActor () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail(message, file: file, line: line)
                throw CocoaError(.executableRuntimeMismatch)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

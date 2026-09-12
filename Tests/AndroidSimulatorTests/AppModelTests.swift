import XCTest
import Combine
@testable import AndroidSimulator
import SimulatorKit

@MainActor
final class AppModelTests: XCTestCase {
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

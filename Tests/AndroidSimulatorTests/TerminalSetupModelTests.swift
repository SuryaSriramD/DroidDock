import XCTest
@testable import AndroidSimulator
import SimulatorKit

@MainActor
final class TerminalSetupModelTests: XCTestCase {
    func testOnlyApplicationsInstallsCanOfferOrApplyTerminalSetup() async throws {
        let home = URL(fileURLWithPath: "/Users/terminal-fixture")
        for path in ["/Volumes/DroidDock/DroidDock.app", "/tmp/artifacts/DroidDock.app", "/ApplicationsNotReally/DroidDock.app"] {
            let defaults = try isolatedDefaults()
            let model = TerminalSetupModel(appBundle: URL(fileURLWithPath: path), homeDirectory: home, defaults: defaults) { _, _ in
                XCTFail("An uninstalled app must not write terminal configuration")
            }
            await model.configure(sdk: nil)
            model.presentIfNeeded()
            await model.applySetup()
            XCTAssertEqual(model.state, .requiresInstallation)
            XCTAssertFalse(model.canSetUp)
            XCTAssertFalse(model.isPresented)
            XCTAssertFalse(defaults.bool(forKey: TerminalSetupModel.offeredDefaultsKey))
        }
        XCTAssertTrue(TerminalSetupModel.isInstalledApplication(URL(fileURLWithPath: "/Applications/DroidDock.app"), homeDirectory: home))
        XCTAssertTrue(TerminalSetupModel.isInstalledApplication(home.appendingPathComponent("Applications/DroidDock.app"), homeDirectory: home))
    }

    func testDiscoveryIsReadOnlyUntilExplicitActionAndLaterSDKChangesStayInSync() async throws {
        let recorder = Recorder()
        let defaults = try isolatedDefaults()
        let model = makeModel(recorder, defaults: defaults)
        await model.configure(sdk: nil)
        await model.configure(sdk: nil)
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.isEnabled)
        let initialRequests = await recorder.requests
        XCTAssertEqual(initialRequests.count, 0)
        await model.applySetup()
        XCTAssertEqual(model.state, .ready(hasAndroid: false))
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: TerminalSetupModel.enabledDefaultsKey))
        let sdk = sdk("managed")
        await model.configure(sdk: sdk)
        await model.configure(sdk: sdk)
        let requests = await recorder.requests
        XCTAssertEqual(requests, [nil, sdk])
        XCTAssertEqual(model.state, .ready(hasAndroid: true))
        XCTAssertEqual(model.selectedSDK, sdk)
        XCTAssertFalse(model.isWorking)
    }

    func testLaterRemembersOfferedPromptAcrossRelaunchWithoutWritingProfiles() async throws {
        let recorder = Recorder()
        let defaults = try isolatedDefaults()
        let model = makeModel(recorder, defaults: defaults)
        await model.configure(sdk: sdk("discovered"))
        model.presentIfNeeded()
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(model.canSetUp)
        model.dismissSetup()
        XCTAssertFalse(model.isPresented)
        model.presentIfNeeded()
        XCTAssertFalse(model.isPresented)
        let reopened = makeModel(recorder, defaults: defaults)
        await reopened.configure(sdk: sdk("another"))
        reopened.presentIfNeeded()
        XCTAssertFalse(reopened.isPresented)
        XCTAssertFalse(reopened.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: TerminalSetupModel.enabledDefaultsKey))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 0)
        reopened.presentSetup()
        XCTAssertTrue(reopened.isPresented, "Settings can reopen setup after Later")
    }

    func testSuccessfulConsentPersistsAcrossRelaunchAndDoesNotPromptAgain() async throws {
        let recorder = Recorder()
        let defaults = try isolatedDefaults()
        let sdk = sdk("selected")
        let model = makeModel(recorder, defaults: defaults)
        await model.configure(sdk: sdk)
        await model.applySetup()
        let reopened = makeModel(recorder, defaults: defaults)
        XCTAssertTrue(reopened.isEnabled)
        reopened.presentIfNeeded()
        XCTAssertFalse(reopened.isPresented)
        await reopened.configure(sdk: sdk)
        await reopened.configure(sdk: sdk)
        let requests = await recorder.requests
        XCTAssertEqual(requests, [sdk, sdk], "One approved synchronization per launch; repeated refresh stays quiet")
        XCTAssertEqual(reopened.state, .ready(hasAndroid: true))
    }

    func testSDKChangeDuringSetupIsSerializedAndPublishesTheLatestConfiguration() async throws {
        let recorder = Recorder(holdFirst: true)
        let model = makeModel(recorder, defaults: try isolatedDefaults())
        let firstSDK = sdk("first"), secondSDK = sdk("second")
        await model.configure(sdk: firstSDK)
        let first = Task { await model.applySetup() }
        try await eventually { await recorder.isHeld }
        let second = Task { await model.configure(sdk: secondSDK) }
        await Task.yield()
        let before = await recorder.requests
        XCTAssertEqual(before, [firstSDK])
        XCTAssertTrue(model.isWorking)
        XCTAssertFalse(model.isEnabled, "Consent is persisted only after successful setup")
        await recorder.release()
        await first.value; await second.value
        let after = await recorder.requests
        XCTAssertEqual(after, [firstSDK, secondSDK])
        XCTAssertEqual(model.state, .ready(hasAndroid: true))
        XCTAssertTrue(model.isEnabled)
        XCTAssertFalse(model.isWorking)
    }

    func testFailedExplicitSetupDoesNotEnableAutomaticWritesAndCanBeRetried() async throws {
        let recorder = Recorder(failFirst: true)
        let defaults = try isolatedDefaults()
        let model = makeModel(recorder, defaults: defaults)
        await model.configure(sdk: nil)
        await model.applySetup()
        guard case .failed = model.state else { return XCTFail("Setup errors must be visible") }
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: TerminalSetupModel.enabledDefaultsKey))
        await model.configure(sdk: nil)
        await model.configure(sdk: sdk("changed-after-failure"))
        let before = await recorder.requests
        XCTAssertEqual(before.count, 1)
        let reopened = makeModel(recorder, defaults: defaults)
        await reopened.configure(sdk: nil)
        reopened.presentIfNeeded()
        XCTAssertFalse(reopened.isPresented)
        let afterReopen = await recorder.requests
        XCTAssertEqual(afterReopen.count, 1)
        await reopened.applySetup()
        let after = await recorder.requests
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(reopened.state, .ready(hasAndroid: false))
        XCTAssertTrue(reopened.isEnabled)
    }

    func testFailedAutomaticSDKSyncWaitsForExplicitRetryInsteadOfEveryRefresh() async throws {
        let recorder = Recorder(failingRequests: [2])
        let model = makeModel(recorder, defaults: try isolatedDefaults())
        await model.configure(sdk: nil)
        await model.applySetup()
        let selected = sdk("new-sdk")
        await model.configure(sdk: selected)
        guard case .failed = model.state else { return XCTFail("Expected synchronization error") }
        XCTAssertTrue(model.isEnabled)
        await model.configure(sdk: selected)
        await model.configure(sdk: selected)
        let before = await recorder.requests
        XCTAssertEqual(before, [nil, selected])
        await model.applySetup()
        let after = await recorder.requests
        XCTAssertEqual(after, [nil, selected, selected])
        XCTAssertEqual(model.state, .ready(hasAndroid: true))
    }

    func testShutdownCanJoinPendingProfileWrite() async throws {
        let recorder = Recorder(holdFirst: true)
        let model = makeModel(recorder, defaults: try isolatedDefaults())
        await model.configure(sdk: nil)
        let setup = Task { await model.applySetup() }
        try await eventually { await recorder.isHeld }
        var joined = false
        let join = Task { await model.waitForSetup(); joined = true }
        await Task.yield()
        XCTAssertFalse(joined)
        await recorder.release()
        await join.value; await setup.value
        XCTAssertTrue(joined)
        XCTAssertFalse(model.isWorking)
    }

    func testDiscoveryRefreshDoesNotWriteProfilesUntilUserAppliesSetupOrStartAPhone() async throws {
        let fixture = try FixtureSDK(avdName: "Terminal_Fixture")
        let recorder = Recorder()
        let terminal = makeModel(recorder, defaults: try isolatedDefaults())
        let model = AppModel(runtimeLedger: RuntimeLedger(url: fixture.root.appendingPathComponent("ledger.json")), terminalSetup: terminal)
        model.sdkPath = fixture.installation.root.path
        addTeardownBlock { @MainActor in
            await model.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await model.refresh()
        let before = await recorder.requests
        XCTAssertEqual(before.count, 0)
        XCTAssertEqual(terminal.selectedSDK?.root, model.sdk?.root)
        XCTAssertEqual(terminal.state, .idle)
        await terminal.applySetup()
        await model.refresh()
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.compactMap { $0 }.first?.root, model.sdk?.root)
        XCTAssertEqual(terminal.state, .ready(hasAndroid: true))
        XCTAssertEqual(try fixture.launchCount(), 0)
    }

    private func makeModel(_ recorder: Recorder, defaults: UserDefaults) -> TerminalSetupModel {
        TerminalSetupModel(appBundle: URL(fileURLWithPath: "/Applications/DroidDock.app"), defaults: defaults) { _, sdk in
            try await recorder.install(sdk)
        }
    }

    func testSetupPresentationCannotCompeteWithAndroidOrUpdateSheets() throws {
        let terminal = makeModel(Recorder(), defaults: try isolatedDefaults())
        let model = AppModel(terminalSetup: terminal)
        model.showingAndroidSetup = true
        XCTAssertFalse(model.canPresentTerminalSetup)
        model.presentTerminalSetup()
        XCTAssertFalse(terminal.isPresented)
        model.showingAndroidSetup = false
        terminal.presentSetup()
        XCTAssertFalse(model.canPresentAppUpdates)
        model.presentAppUpdates()
        XCTAssertFalse(AppUpdateModel.shared.showingUpdateSheet)
        model.presentAndroidVersions()
        XCTAssertFalse(model.showingAndroidSetup)
        terminal.dismissSetup()
        XCTAssertTrue(model.canPresentAppUpdates)
        XCTAssertTrue(model.canPresentTerminalSetup)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "DroidDock.TerminalSetupModelTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func sdk(_ name: String) -> SDKInstallation {
        let root = URL(fileURLWithPath: "/tmp/terminal-sdk-" + name)
        return SDKInstallation(root: root, emulator: root.appendingPathComponent("emulator/emulator"), adb: root.appendingPathComponent("platform-tools/adb"))
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < end else { throw CocoaError(.executableRuntimeMismatch) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private actor Recorder {
        var requests: [SDKInstallation?] = []
        var isHeld = false
        let holdFirst: Bool
        let failFirst: Bool
        let failingRequests: Set<Int>
        private var continuation: CheckedContinuation<Void, Never>?
        init(holdFirst: Bool = false, failFirst: Bool = false, failingRequests: Set<Int> = []) {
            self.holdFirst = holdFirst; self.failFirst = failFirst; self.failingRequests = failingRequests
        }
        func install(_ sdk: SDKInstallation?) async throws {
            requests.append(sdk)
            if (failFirst && requests.count == 1) || failingRequests.contains(requests.count) { throw CocoaError(.fileWriteNoPermission) }
            if holdFirst && requests.count == 1 {
                await withCheckedContinuation { continuation = $0; isHeld = true }
            }
        }
        func release() { continuation?.resume(); continuation = nil; isHeld = false }
    }
}

import XCTest
@testable import AndroidSimulator
@testable import SimulatorKit

@MainActor
final class AppUpdateModelTests: XCTestCase {
    func testAutomaticChecksRunAtMostOncePerDayAndStayQuietWhenCurrent() async {
        let preferences = MemoryPreferences(), clock = Clock()
        var calls = 0
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: preferences, now: { clock.date }, load: { version in
            calls += 1; XCTAssertEqual(version, "0.3.2")
            return .upToDate(latestVersion: "0.3.2")
        })
        await model.checkAutomaticallyIfNeeded()
        await model.checkAutomaticallyIfNeeded()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.showingUpdateSheet)
        XCTAssertEqual(model.lastChecked, clock.date)
        clock.date.addTimeInterval(AppUpdateModel.automaticCheckInterval - 1)
        await model.checkAutomaticallyIfNeeded()
        XCTAssertEqual(calls, 1)
        clock.date.addTimeInterval(1)
        await model.checkAutomaticallyIfNeeded()
        XCTAssertEqual(calls, 2)
    }

    func testAutomaticOptOutPersistsButManualCheckStillWorks() async {
        let preferences = MemoryPreferences()
        var calls = 0
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: preferences, load: { _ in
            calls += 1; return .upToDate(latestVersion: "0.3.2")
        })
        model.automaticallyChecks = false
        XCTAssertFalse(preferences.automaticallyChecks)
        await model.checkAutomaticallyIfNeeded()
        XCTAssertEqual(calls, 0)
        model.checkForUpdates()
        await model.waitForCheck()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.showingUpdateSheet)
        let reopened = AppUpdateModel(installedVersion: "0.3.2", preferences: preferences, load: { _ in
            XCTFail("Disabled automatic checks must stay disabled after relaunch")
            return .upToDate(latestVersion: "0.3.2")
        })
        XCTAssertFalse(reopened.automaticallyChecks)
        XCTAssertEqual(reopened.lastChecked, model.lastChecked)
        await reopened.checkAutomaticallyIfNeeded()
    }

    func testFailedAutomaticCheckIsDistinctFromUpToDateAndCanBeRetriedManually() async {
        let preferences = MemoryPreferences()
        var calls = 0
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: preferences, load: { _ in
            calls += 1
            if calls == 1 { throw AppReleaseCheckError.offline }
            return .upToDate(latestVersion: "0.3.2")
        })
        await model.checkAutomaticallyIfNeeded()
        XCTAssertEqual(model.state, .failed(AppReleaseCheckError.offline.localizedDescription))
        XCTAssertNil(model.lastChecked)
        XCTAssertNil(preferences.lastSuccessfulCheck)
        XCTAssertFalse(model.showingUpdateSheet)
        await model.checkAutomaticallyIfNeeded()
        XCTAssertEqual(calls, 1, "Failures must not repeatedly contact GitHub on every launch")
        model.checkForUpdates()
        await model.waitForCheck()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.state, .upToDate(latestVersion: "0.3.2"))
        XCTAssertNotNil(model.lastChecked)
    }

    func testNewReleaseOpensAutomaticResultSheet() async {
        let release = update()
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: MemoryPreferences(), load: { _ in .available(release) })
        await model.checkAutomaticallyIfNeeded()
        XCTAssertEqual(model.state, .available(release))
        XCTAssertTrue(model.showingUpdateSheet)
    }

    func testNewerLocalBuildDoesNotPromptForDowngrade() async {
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: MemoryPreferences(), load: { _ in
            .newerLocalBuild(latestVersion: "0.2.1")
        })
        await model.checkAutomaticallyIfNeeded()
        XCTAssertEqual(model.state, .newerLocalBuild(latestVersion: "0.2.1"))
        XCTAssertFalse(model.showingUpdateSheet)
    }

    func testDelayedAutomaticResultWaitsForOtherSheetAndIsPresentedOnlyOnce() async throws {
        let gate = Gate(), release = update()
        var canPresent = true, calls = 0
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: MemoryPreferences(),
            canPresentAutomatically: { canPresent }, load: { _ in
                calls += 1
                try await gate.wait()
                return .available(release)
            })
        let automatic = Task { await model.checkAutomaticallyIfNeeded() }
        try await eventually { gate.started }
        canPresent = false
        gate.released = true
        await automatic.value
        XCTAssertEqual(model.state, .available(release))
        XCTAssertFalse(model.showingUpdateSheet)
        await model.checkAutomaticallyIfNeeded()
        XCTAssertFalse(model.showingUpdateSheet)
        canPresent = true
        await model.checkAutomaticallyIfNeeded()
        XCTAssertTrue(model.showingUpdateSheet)
        XCTAssertEqual(calls, 1)
        model.showingUpdateSheet = false
        await model.checkAutomaticallyIfNeeded()
        XCTAssertFalse(model.showingUpdateSheet, "Dismissing the result must not repeatedly reopen it")
    }

    func testManualRequestJoinsAnInFlightAutomaticCheck() async throws {
        let gate = Gate()
        var calls = 0
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: MemoryPreferences(), load: { _ in
            calls += 1
            try await gate.wait()
            return .upToDate(latestVersion: "0.3.2")
        })
        let automatic = Task { await model.checkAutomaticallyIfNeeded() }
        try await eventually { gate.started }
        model.checkForUpdates()
        model.checkForUpdates()
        XCTAssertTrue(model.showingUpdateSheet)
        XCTAssertEqual(calls, 1)
        gate.released = true
        await automatic.value
        XCTAssertEqual(model.state, .upToDate(latestVersion: "0.3.2"))
        XCTAssertFalse(model.isChecking)
    }

    func testOptOutDuringAutomaticCheckSuppressesNewReleasePrompt() async throws {
        let gate = Gate(), release = update()
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: MemoryPreferences(), load: { _ in
            try await gate.wait(); return .available(release)
        })
        let automatic = Task { await model.checkAutomaticallyIfNeeded() }
        try await eventually { gate.started }
        model.automaticallyChecks = false
        gate.released = true
        await automatic.value
        XCTAssertFalse(model.showingUpdateSheet)
    }

    func testCancellationDoesNotBecomeSuccessfulOrFailedCheck() async throws {
        let gate = Gate(), preferences = MemoryPreferences()
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: preferences, load: { _ in
            do { try await gate.wait() } catch { throw URLError(.cancelled) }
            return .upToDate(latestVersion: "0.3.2")
        })
        model.checkForUpdates()
        try await eventually { gate.started }
        await model.cancel()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.lastChecked)
        XCTAssertFalse(model.isChecking)
    }

    func testClockMovingBackwardDoesNotDisableChecksIndefinitely() async {
        let preferences = MemoryPreferences(), clock = Clock()
        preferences.lastAttempt = clock.date.addingTimeInterval(30 * 24 * 60 * 60)
        var calls = 0
        let model = AppUpdateModel(installedVersion: "0.3.2", preferences: preferences, now: { clock.date }, load: { _ in
            calls += 1; return .upToDate(latestVersion: "0.3.2")
        })
        await model.checkAutomaticallyIfNeeded()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(preferences.lastAttempt, clock.date)
    }

    private func update() -> AppReleaseUpdate {
        AppReleaseUpdate(version: "0.4.0",
                         releaseURL: URL(string: "https://github.com/SuryaSriramD/DroidDock/releases/tag/v0.4.0")!,
                         downloadURL: URL(string: "https://github.com/SuryaSriramD/DroidDock/releases/download/v0.4.0/DroidDock-macOS.dmg")!)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw AppReleaseCheckError.timedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor private final class MemoryPreferences: AppUpdatePreferences {
        var automaticallyChecks = true
        var lastAttempt: Date?
        var lastSuccessfulCheck: Date?
    }
    @MainActor private final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }
    @MainActor private final class Gate {
        var started = false
        var released = false
        func wait() async throws {
            started = true
            while !released { try await Task.sleep(nanoseconds: 1_000_000) }
        }
    }
}

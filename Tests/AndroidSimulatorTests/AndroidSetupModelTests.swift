import XCTest
@testable import AndroidSimulator
import SimulatorKit

@MainActor
final class AndroidSetupModelTests: XCTestCase {
    private var plan: AndroidInstallPlan { AndroidInstallPlan(packages: [], licenses: []) }
    private var newerPlan: AndroidInstallPlan {
        AndroidInstallPlan(packages: [], licenses: [], runtime: AndroidRuntimeVersion(packageID: "system-images;android-37.0;google_apis;arm64-v8a")!)
    }
    private var downloadNeeded: AndroidVersionAvailability {
        AndroidVersionAvailability(downloadBytes: 100, requiredDiskBytes: 1000, installed: false, phoneExists: false)
    }

    func testInstallationRequiresReviewAndExplicitAcceptance() async throws {
        var installs = 0
        let fixture = plan
        let needsDownload = downloadNeeded
        let model = AndroidSetupModel(load: { [fixture] }, inspect: { _ in needsDownload }, install: { _, progress in
            installs += 1
            progress(AndroidSetupProgress(message: "Done", fraction: 1))
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.acceptedLicenses = true
        model.startInstall()
        XCTAssertEqual(installs, 0)
        model.prepare()
        try await settle(model)
        XCTAssertEqual(model.stage, .versions)
        XCTAssertNil(model.plan)
        XCTAssertFalse(model.acceptedLicenses)
        model.startInstall()
        XCTAssertEqual(installs, 0)
        model.selectVersion(id: fixture.runtime.id)
        XCTAssertEqual(model.stage, .review)
        XCTAssertFalse(model.canInstall)
        model.startInstall()
        XCTAssertEqual(installs, 0)
        model.acceptedLicenses = true
        model.startInstall()
        model.startInstall() // Double-click must not start another installation.
        try await settle(model)
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(model.installedSDK?.path, "/fixture/sdk")
        model.resetCompletedSetup()
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertNil(model.installedSDK)
        XCTAssertFalse(model.acceptedLicenses)
    }

    func testFailureCanBeRetriedWithoutPublishingAnSDK() async throws {
        var attempts = 0
        let fixture = plan
        let needsDownload = downloadNeeded
        let model = AndroidSetupModel(load: { [fixture] }, inspect: { _ in needsDownload }, install: { _, _ in
            attempts += 1
            if attempts == 1 { throw RuntimeError.invalidArgument("Download interrupted") }
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.prepare(); try await settle(model)
        model.selectVersion(id: fixture.runtime.id)
        model.acceptedLicenses = true; model.startInstall(); try await settle(model)
        XCTAssertEqual(model.stage, .review)
        XCTAssertNil(model.installedSDK)
        XCTAssertEqual(model.error, "Download interrupted")
        model.startInstall(); try await settle(model)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertNil(model.error)
    }

    func testCancelAwaitsCleanupAndNeverPublishesSuccess() async throws {
        let fixture = plan
        var cleanedUp = false
        let needsDownload = downloadNeeded
        let model = AndroidSetupModel(load: { [fixture] }, inspect: { _ in needsDownload }, install: { _, _ in
            defer { cleanedUp = true }
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.prepare(); try await settle(model)
        model.selectVersion(id: fixture.runtime.id)
        model.acceptedLicenses = true; model.startInstall()
        await Task.yield()
        await model.cancel()
        XCTAssertTrue(cleanedUp)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.installedSDK)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.stage, .review)
    }

    func testRefreshingPlanResetsPreviousConsent() async throws {
        var loads = 0
        let fixture = plan
        let needsDownload = downloadNeeded
        let model = AndroidSetupModel(load: {
            loads += 1
            if loads == 2 { throw RuntimeError.invalidArgument("Offline") }
            return [fixture]
        }, inspect: { _ in needsDownload }, install: { _, _ in XCTFail("No install expected"); return URL(fileURLWithPath: "/fixture/sdk") })
        model.prepare(); try await settle(model)
        model.selectVersion(id: fixture.runtime.id)
        model.acceptedLicenses = true
        model.prepare(); try await settle(model)
        XCTAssertNil(model.plan)
        XCTAssertFalse(model.acceptedLicenses)
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertEqual(model.error, "Offline")
    }

    func testURLSessionCancellationDoesNotBecomeAnError() async throws {
        let model = AndroidSetupModel(load: {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { throw URLError(.cancelled) }
            return [AndroidInstallPlan(packages: [], licenses: [])]
        }, inspect: { _ in XCTFail("Cancelled catalog must not be inspected"); throw CancellationError() })
        model.prepare()
        await Task.yield()
        await model.cancel()
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertNil(model.error)
        XCTAssertNil(model.plan)
    }

    func testCatalogDoesNotAutoSelectAndInstallsOnlyExplicitlyChosenVersion() async throws {
        let older = plan, newer = newerPlan
        let needsDownload = downloadNeeded
        var installedIDs: [String] = []
        let model = AndroidSetupModel(load: { [newer, older] }, inspect: { _ in needsDownload }, install: { selection, _ in
            installedIDs.append(selection.runtime.id)
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.prepare(); try await settle(model)
        XCTAssertEqual(model.stage, .versions)
        XCTAssertEqual(model.versions.map { $0.runtime.id }, [newer.runtime.id, older.runtime.id])
        XCTAssertNil(model.plan)
        XCTAssertFalse(model.canInstall)
        model.acceptedLicenses = true
        model.startInstall()
        model.selectVersion(id: "unknown version")
        XCTAssertTrue(installedIDs.isEmpty)
        XCTAssertNil(model.plan)
        model.selectVersion(id: older.runtime.id)
        XCTAssertEqual(model.plan, older)
        XCTAssertFalse(model.acceptedLicenses)
        model.acceptedLicenses = true
        model.startInstall(); try await settle(model)
        XCTAssertEqual(installedIDs, [older.runtime.id])
        XCTAssertEqual(model.installedDeviceName, older.runtime.deviceName)
    }

    func testSwitchingVersionsClearsConsentAndReviewedSelection() async throws {
        let older = plan, newer = newerPlan
        let needsDownload = downloadNeeded
        var installs = 0
        let model = AndroidSetupModel(load: { [newer, older] }, inspect: { _ in needsDownload }, install: { _, _ in
            installs += 1
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.prepare(); try await settle(model)
        model.selectVersion(id: newer.runtime.id)
        model.acceptedLicenses = true
        XCTAssertTrue(model.canInstall)
        model.backToVersions()
        XCTAssertEqual(model.stage, .versions)
        XCTAssertNil(model.plan)
        XCTAssertNil(model.reviewedAvailability)
        XCTAssertFalse(model.acceptedLicenses)
        model.selectVersion(id: older.runtime.id)
        XCTAssertEqual(model.plan, older)
        XCTAssertFalse(model.acceptedLicenses)
        XCTAssertFalse(model.canInstall)
        model.startInstall()
        XCTAssertEqual(installs, 0)
    }

    func testChangedAvailabilityRequiresFreshReviewBeforeInstallation() async throws {
        let fixture = newerPlan
        var current = downloadNeeded
        var installs = 0
        let model = AndroidSetupModel(load: { [fixture] }, inspect: { _ in current }, install: { selection, _ in
            XCTAssertEqual(selection, fixture)
            installs += 1
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.prepare(); try await settle(model)
        model.selectVersion(id: fixture.runtime.id)
        model.acceptedLicenses = true
        current = AndroidVersionAvailability(downloadBytes: 200, requiredDiskBytes: 2000, installed: false, phoneExists: false)
        model.startInstall()
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(model.stage, .review)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.acceptedLicenses)
        XCTAssertFalse(model.canInstall)
        XCTAssertEqual(model.reviewedAvailability, current)
        XCTAssertEqual(model.availability[fixture.runtime.id], current)
        XCTAssertTrue(model.error?.contains("changed") == true)
        model.acceptedLicenses = true
        model.startInstall(); try await settle(model)
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertNil(model.error)
    }

    func testInstalledPhoneCompletesSelectionWithoutDownloadOrConsent() async throws {
        let fixture = newerPlan
        let sdk = URL(fileURLWithPath: "/fixture/existing-sdk")
        let alreadyInstalled = AndroidVersionAvailability(downloadBytes: 0, requiredDiskBytes: 0, installed: true, phoneExists: true)
        let model = AndroidSetupModel(load: { [fixture] }, inspect: { _ in alreadyInstalled }, sdkRoot: sdk, install: { _, _ in
            XCTFail("Selecting an existing phone must not reinstall it")
            return sdk
        })
        model.prepare(); try await settle(model)
        model.selectVersion(id: fixture.runtime.id)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(model.installedSDK, sdk)
        XCTAssertEqual(model.installedDeviceName, fixture.runtime.deviceName)
        XCTAssertFalse(model.acceptedLicenses)
        XCTAssertFalse(model.canInstall)
        model.startInstall()
        XCTAssertFalse(model.isBusy)
    }

    func testRecreatingPhoneWithInstalledImageNeedsNoDownloadConsent() async throws {
        let fixture = plan
        let imageOnly = AndroidVersionAvailability(downloadBytes: 0, requiredDiskBytes: 1000, installed: true, phoneExists: false)
        var installs = 0
        let model = AndroidSetupModel(load: { [fixture] }, inspect: { _ in imageOnly }, install: { selection, _ in
            XCTAssertEqual(selection, fixture)
            installs += 1
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.prepare(); try await settle(model)
        model.selectVersion(id: fixture.runtime.id)
        XCTAssertEqual(model.stage, .review)
        XCTAssertFalse(model.needsDownload)
        XCTAssertFalse(model.acceptedLicenses)
        XCTAssertTrue(model.canInstall)
        model.startInstall(); try await settle(model)
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(model.installedDeviceName, fixture.runtime.deviceName)
    }

    func testEmptyCatalogReturnsActionableErrorWithoutInspectingOrInstalling() async throws {
        let model = AndroidSetupModel(load: { [] }, inspect: { _ in
            XCTFail("An empty catalog has nothing to inspect")
            throw CancellationError()
        }, install: { _, _ in
            XCTFail("An empty catalog must not start an installation")
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.prepare(); try await settle(model)
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertTrue(model.versions.isEmpty)
        XCTAssertNil(model.plan)
        XCTAssertNil(model.installedSDK)
        XCTAssertTrue(model.error?.contains("No compatible Android versions") == true)
        XCTAssertFalse(model.canInstall)
    }

    func testInspectionFailureLeavesOtherVersionSelectable() async throws {
        let older = plan, newer = newerPlan
        let needsDownload = downloadNeeded
        let model = AndroidSetupModel(load: { [newer, older] }, inspect: { selection in
            if selection.runtime == newer.runtime { throw RuntimeError.invalidArgument("Emulator update required") }
            return needsDownload
        }, install: { _, _ in
            XCTFail("No install expected")
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.prepare(); try await settle(model)
        XCTAssertEqual(model.stage, .versions)
        XCTAssertEqual(model.availabilityErrors[newer.runtime.id], "Emulator update required")
        XCTAssertEqual(model.availability[older.runtime.id], needsDownload)
        model.selectVersion(id: newer.runtime.id)
        XCTAssertEqual(model.stage, .versions)
        XCTAssertNil(model.plan)
        XCTAssertEqual(model.error, "Emulator update required")
        model.selectVersion(id: older.runtime.id)
        XCTAssertEqual(model.stage, .review)
        XCTAssertEqual(model.plan, older)
        XCTAssertNil(model.error)
    }

    func testReopeningPresentationClearsDismissedReviewAndConsent() async throws {
        let fixture = plan
        let needsDownload = downloadNeeded
        let model = AndroidSetupModel(load: { [fixture] }, inspect: { _ in needsDownload }, install: { _, _ in
            XCTFail("Reopening setup must not start an installation")
            return URL(fileURLWithPath: "/fixture/sdk")
        })
        model.beginPresentation(loadCatalog: true)
        try await settle(model)
        model.selectVersion(id: fixture.runtime.id)
        model.acceptedLicenses = true
        XCTAssertTrue(model.canInstall)
        let dismissedPresentation = model.presentationID
        await model.cancel(presentationID: dismissedPresentation)

        model.beginPresentation(loadCatalog: false)
        XCTAssertNotEqual(model.presentationID, dismissedPresentation)
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertNil(model.plan)
        XCTAssertNil(model.reviewedAvailability)
        XCTAssertNil(model.installedSDK)
        XCTAssertFalse(model.acceptedLicenses)
        XCTAssertFalse(model.canInstall)
        XCTAssertTrue(model.versions.isEmpty)
        XCTAssertTrue(model.availability.isEmpty)
        model.startInstall()
        XCTAssertFalse(model.isBusy)
    }

    func testPreviousPresentationCancellationDoesNotCancelNewCatalogLoad() async {
        let model = AndroidSetupModel(load: {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return []
        }, inspect: { _ in
            XCTFail("The fixture catalog never completes")
            throw CancellationError()
        })
        model.beginPresentation(loadCatalog: false)
        let dismissedPresentation = model.presentationID
        model.beginPresentation(loadCatalog: true)
        let activePresentation = model.presentationID
        XCTAssertNotEqual(activePresentation, dismissedPresentation)

        await model.cancel(presentationID: dismissedPresentation)
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.stage, .loading)
        XCTAssertNil(model.error)

        await model.cancel(presentationID: activePresentation)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertNil(model.error)
    }

    private func settle(_ model: AndroidSetupModel) async throws {
        let deadline = Date().addingTimeInterval(3)
        while model.isBusy {
            if Date() >= deadline { XCTFail("Setup did not finish"); throw CocoaError(.executableRuntimeMismatch) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

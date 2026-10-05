import CryptoKit
import XCTest
@testable import SimulatorKit

final class ManagedAndroidRuntimeTests: XCTestCase {
    func testInstallPublishesCompleteSDKAndIsolatedPhoneAndExactConsentRecord() async throws {
        let fixture = try fixture()
        let unrelated = fixture.parent.appendingPathComponent("existing-android.avd")
        try Data("user's Android data".utf8).write(to: unrelated)
        let sdk = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        XCTAssertEqual(sdk, fixture.root.appendingPathComponent("sdk"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sdk.appendingPathComponent(".droiddock-managed").path))
        let config = AVDRepository.readINI(at: fixture.device.appendingPathComponent("config.ini"))
        XCTAssertEqual(config["image.sysdir.1"], "system-images/android-36/google_apis/arm64-v8a/")
        XCTAssertEqual(config["hw.ramSize"], "2048")
        XCTAssertEqual(config["hw.lcd.width"], "1080")
        XCTAssertEqual(config["abi.type"], "arm64-v8a")
        let index = AVDRepository.readINI(at: fixture.root.appendingPathComponent("avd/\(ManagedAndroidRuntime.deviceName).ini"))
        XCTAssertEqual(index["path"], fixture.device.path)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sdk.appendingPathComponent("droiddock-license-acceptance.json"))) as? [String: Any])
        let licenses = try XCTUnwrap(record["licenses"] as? [[String: String]])
        XCTAssertEqual(licenses.first?["text"], fixture.plan.licenses.first?.text)
        XCTAssertEqual(licenses.first?["sha256"], digest(Data(fixture.plan.licenses[0].text.utf8)))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "user's Android data")
        await assertCalls(fixture.calls, downloads: 3)
        try assertNoStaging(fixture.root)
    }

    func testReadyInstallationReusesDownloadAndPreservesPhoneDataAndSettings() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let config = fixture.device.appendingPathComponent("config.ini")
        let data = fixture.device.appendingPathComponent("userdata-qemu.img")
        try Data("personal settings".utf8).write(to: config)
        try Data("installed apps and data".utf8).write(to: data)
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        await assertCalls(fixture.calls, downloads: 3)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "personal settings")
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "installed apps and data")
    }

    func testModernAndroidImageUsesEmptyDataDiskWithoutLegacyUserdataImage() async throws {
        let fixture = try fixture(modernImage: true)
        let sdk = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let image = sdk.appendingPathComponent(ManagedAndroidRuntime.imagePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.appendingPathComponent("data/empty_data_disk").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.appendingPathComponent("userdata.img").path))
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        await assertCalls(fixture.calls, downloads: 3)
    }

    func testAdditionalAPIOnlyDownloadsItsImageAndPreservesOriginalPhoneAndSharedTools() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let originalConfig = fixture.device.appendingPathComponent("config.ini")
        try Data("avd.ini.displayname=My existing phone\ncustom=keep\n".utf8).write(to: originalConfig)
        let userData = fixture.device.appendingPathComponent("userdata-qemu.img")
        try Data("my installed apps".utf8).write(to: userData)
        let sdk = fixture.runtime.sdkRoot
        let preserved = [originalConfig, userData, sdk.appendingPathComponent("emulator/emulator"),
                         sdk.appendingPathComponent("emulator/.droiddock-package.json"),
                         sdk.appendingPathComponent("platform-tools/adb"),
                         sdk.appendingPathComponent(ManagedAndroidRuntime.imagePath + "/system.img"),
                         sdk.appendingPathComponent("droiddock-license-acceptance.json")]
        let before = try preserved.map { try Data(contentsOf: $0) }
        let next = plan(api: "37.0", emulatorRevision: "38.0.0", minimumEmulator: "36.5.11")
        XCTAssertEqual(try fixture.runtime.packagesToDownload(for: next).map(\.id), [next.runtime.id])
        XCTAssertEqual(try fixture.runtime.missingDownloadBytes(for: next), next.packages[2].archiveBytes)
        XCTAssertFalse(fixture.runtime.isRuntimeInstalled(next.runtime))
        XCTAssertFalse(fixture.runtime.phoneExists(next.runtime))
        let installedSDK = try await fixture.runtime.install(plan: next) { _ in }
        XCTAssertEqual(installedSDK, sdk)
        await assertCalls(fixture.calls, downloads: 4, extractions: 4)
        XCTAssertEqual(try preserved.map { try Data(contentsOf: $0) }, before)
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(.legacy))
        XCTAssertTrue(fixture.runtime.phoneExists(.legacy))
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(next.runtime))
        XCTAssertTrue(fixture.runtime.phoneExists(next.runtime))
        XCTAssertEqual(try fixture.runtime.missingDownloadBytes(for: next), 0)
        XCTAssertEqual(try fixture.runtime.requiredAdditionalDiskBytes(for: next), 0)
        let newConfig = AVDRepository.readINI(at: fixture.runtime.avdHome.appendingPathComponent(next.runtime.deviceName + ".avd/config.ini"))
        XCTAssertEqual(newConfig["avd.ini.displayname"], next.runtime.title + " Phone")
        XCTAssertEqual(newConfig["image.sysdir.1"], next.runtime.imagePath + "/")
        XCTAssertEqual(newConfig["target"], "android-37.0")
        let receiptURL = sdk.appendingPathComponent(next.runtime.imagePath + "/.droiddock-package.json")
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        XCTAssertEqual(receipt["id"] as? String, next.runtime.id)
        XCTAssertEqual(receipt["revision"] as? String, "7.0.0")
        XCTAssertEqual(receipt["checksum"] as? String, next.packages[2].checksum)
        XCTAssertEqual((receipt["licenses"] as? [[String: String]])?.first?["text"], next.licenses.first?.text)
        try assertNoStaging(fixture.root)
    }

    func testFreshSetupOfSelectedAPIAndDecimalAPIAreSeparateFromLegacy36() async throws {
        let fixture = try fixture()
        let latest = plan(api: "37.0")
        _ = try await fixture.runtime.install(plan: latest) { _ in }
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(latest.runtime))
        XCTAssertFalse(fixture.runtime.isRuntimeInstalled(.legacy))
        XCTAssertFalse(fixture.runtime.phoneExists(.legacy))
        let decimal = plan(api: "36.1")
        _ = try await fixture.runtime.install(plan: decimal) { _ in }
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(decimal.runtime))
        XCTAssertTrue(fixture.runtime.phoneExists(decimal.runtime))
        XCTAssertEqual(decimal.runtime.deviceName, "DroidDock_Phone_API_36_1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.runtime.sdkRoot.appendingPathComponent("system-images/android-36.1/google_apis/arm64-v8a/system.img").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtime.sdkRoot.appendingPathComponent(ManagedAndroidRuntime.imagePath).path))
        await assertCalls(fixture.calls, downloads: 4)
    }

    func testDeletedPhoneCanBeRecreatedWithoutDownloadingOrChangingInstalledImage() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let image = fixture.runtime.sdkRoot.appendingPathComponent(ManagedAndroidRuntime.imagePath + "/system.img")
        let originalImage = try Data(contentsOf: image)
        try FileManager.default.removeItem(at: fixture.device)
        try FileManager.default.removeItem(at: fixture.runtime.avdHome.appendingPathComponent(ManagedAndroidRuntime.deviceName + ".ini"))
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(.legacy))
        XCTAssertFalse(fixture.runtime.phoneExists(.legacy))
        XCTAssertEqual(try fixture.runtime.missingDownloadBytes(for: fixture.plan), 0)
        XCTAssertEqual(try fixture.runtime.requiredAdditionalDiskBytes(for: fixture.plan), 4 * 1_024 * 1_024 * 1_024)
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        XCTAssertTrue(fixture.runtime.phoneExists(.legacy))
        XCTAssertEqual(try Data(contentsOf: image), originalImage)
        await assertCalls(fixture.calls, downloads: 3)
    }

    func testInstalledImagePatchIsNeverSilentlyReplacedWithNewCatalogRevision() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let receipt = fixture.runtime.sdkRoot.appendingPathComponent(ManagedAndroidRuntime.imagePath + "/.droiddock-package.json")
        let before = try Data(contentsOf: receipt)
        let newer = plan(api: "36", emulatorRevision: "99.0.0", minimumEmulator: "99.0.0", imageRevision: "9.0.0")
        XCTAssertEqual(try fixture.runtime.missingDownloadBytes(for: newer), 0)
        _ = try await fixture.runtime.install(plan: newer) { _ in }
        XCTAssertEqual(try Data(contentsOf: receipt), before)
        await assertCalls(fixture.calls, downloads: 3)
    }

    func testOlderSharedEngineBlocksNewImageWithoutTouchingExistingPhones() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let source = fixture.runtime.sdkRoot.appendingPathComponent("emulator/source.properties")
        try Data("Pkg.Revision=35.4.8\n".utf8).write(to: source)
        let next = plan(api: "37.0", minimumEmulator: "36.5.11")
        XCTAssertThrowsError(try fixture.runtime.missingDownloadBytes(for: next)) {
            XCTAssertEqual($0 as? AndroidSetupError, .sharedToolsUpdateRequired(component: "emulator", minimum: "36.5.11", installed: "35.4.8"))
        }
        do { _ = try await fixture.runtime.install(plan: next) { _ in }; XCTFail("An incompatible engine must not install an image") }
        catch { XCTAssertEqual(error as? AndroidSetupError, .sharedToolsUpdateRequired(component: "emulator", minimum: "36.5.11", installed: "35.4.8")) }
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(.legacy))
        XCTAssertTrue(fixture.runtime.phoneExists(.legacy))
        XCTAssertFalse(fixture.runtime.isRuntimeInstalled(next.runtime))
        XCTAssertFalse(fixture.runtime.phoneExists(next.runtime))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Pkg.Revision=35.4.8\n")
        await assertCalls(fixture.calls, downloads: 3)
    }

    func testLegacySourcePropertiesAllowImageInstallWithoutToolReceipts() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let emulator = fixture.runtime.sdkRoot.appendingPathComponent("emulator")
        try FileManager.default.removeItem(at: emulator.appendingPathComponent(".droiddock-package.json"))
        try Data("Pkg.Revision=37.1.11\n".utf8).write(to: emulator.appendingPathComponent("source.properties"))
        let next = plan(api: "37.0", minimumEmulator: "36.5.11")
        _ = try await fixture.runtime.install(plan: next) { _ in }
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(next.runtime))
        await assertCalls(fixture.calls, downloads: 4)
    }

    func testMissingEngineRevisionFailsClosedWhenImageHasMinimumDependency() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        try FileManager.default.removeItem(at: fixture.runtime.sdkRoot.appendingPathComponent("emulator/.droiddock-package.json"))
        let next = plan(api: "37.0", minimumEmulator: "36.5.11")
        XCTAssertThrowsError(try fixture.runtime.packagesToDownload(for: next)) {
            XCTAssertEqual($0 as? AndroidSetupError, .sharedToolsUpdateRequired(component: "emulator", minimum: "36.5.11", installed: nil))
        }
        await assertCalls(fixture.calls, downloads: 3)
    }

    func testFailedIncrementalImageDownloadLeavesOriginalSDKAndRetryWorks() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let next = plan(api: "37.0")
        var dependencies = fixture.dependencies
        dependencies.download = { package, destination, _ in
            try Data(repeating: 0, count: Int(package.archiveBytes)).write(to: destination)
        }
        do {
            _ = try await ManagedAndroidRuntime(root: fixture.root, dependencies: dependencies).install(plan: next) { _ in }
            XCTFail("Expected failed integrity check")
        } catch { XCTAssertEqual(error as? AndroidSetupError, .checksumMismatch(next.runtime.id)) }
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(.legacy))
        XCTAssertTrue(fixture.runtime.phoneExists(.legacy))
        XCTAssertFalse(fixture.runtime.isRuntimeInstalled(next.runtime))
        XCTAssertFalse(fixture.runtime.phoneExists(next.runtime))
        try assertNoStaging(fixture.root)
        _ = try await fixture.runtime.install(plan: next) { _ in }
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(next.runtime))
        await assertCalls(fixture.calls, downloads: 4)
    }

    func testExistingIncompleteImageAndSymlinkedImageParentArePreserved() async throws {
        for symlink in [false, true] {
            let fixture = try fixture()
            _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
            let next = plan(api: "37.0")
            let apiDirectory = fixture.runtime.sdkRoot.appendingPathComponent("system-images/android-37.0")
            let outside = fixture.parent.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            if symlink { try FileManager.default.createSymbolicLink(at: apiDirectory, withDestinationURL: outside) }
            else {
                let image = fixture.runtime.sdkRoot.appendingPathComponent(next.runtime.imagePath)
                try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
                try Data("preserve partial files".utf8).write(to: image.appendingPathComponent("system.img"))
            }
            XCTAssertThrowsError(try fixture.runtime.packagesToDownload(for: next))
            XCTAssertTrue(fixture.runtime.isRuntimeInstalled(.legacy))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
            await assertCalls(fixture.calls, downloads: 3)
        }
    }

    func testCancellingAdditionalImageKeepsInstalledPhoneAndCleansPartialDownload() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let originalConfig = try Data(contentsOf: fixture.device.appendingPathComponent("config.ini"))
        let next = plan(api: "37.0")
        let inFlight = SetupCalls()
        var dependencies = fixture.dependencies
        dependencies.download = { _, destination, _ in
            try Data("partial image download".utf8).write(to: destination)
            await inFlight.didDownload()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let installer = ManagedAndroidRuntime(root: fixture.root, dependencies: dependencies)
        let task = Task { try await installer.install(plan: next) { _ in } }
        try await waitForDownload(inFlight)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(.legacy))
        XCTAssertTrue(fixture.runtime.phoneExists(.legacy))
        XCTAssertFalse(fixture.runtime.isRuntimeInstalled(next.runtime))
        XCTAssertFalse(fixture.runtime.phoneExists(next.runtime))
        XCTAssertEqual(try Data(contentsOf: fixture.device.appendingPathComponent("config.ini")), originalConfig)
        try assertNoStaging(fixture.root)
        _ = try await fixture.runtime.install(plan: next) { _ in }
        await assertCalls(fixture.calls, downloads: 4)
    }

    func testImagePublicationCollisionPreservesExternalFilesAndDoesNotCreatePhone() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let next = plan(api: "37.0")
        let destination = fixture.runtime.sdkRoot.appendingPathComponent(next.runtime.imagePath)
        let sentinel = destination.appendingPathComponent("external-file")
        var dependencies = fixture.dependencies
        let originalExtract = dependencies.extract
        dependencies.extract = { archive, directory, archiveRoot in
            try await originalExtract(archive, directory, archiveRoot)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("concurrent external file".utf8).write(to: sentinel)
        }
        do {
            _ = try await ManagedAndroidRuntime(root: fixture.root, dependencies: dependencies).install(plan: next) { _ in }
            XCTFail("An image created concurrently must not be overwritten")
        } catch { XCTAssertEqual(error as? AndroidSetupError, .existingInstallation(destination.path)) }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "concurrent external file")
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(.legacy))
        XCTAssertTrue(fixture.runtime.phoneExists(.legacy))
        XCTAssertFalse(fixture.runtime.phoneExists(next.runtime))
        try assertNoStaging(fixture.root)
    }

    func testCancellationAfterImagePublicationLeavesReusableImageAndNoIncompletePhone() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let next = plan(api: "37.0")
        let task = Task {
            try await fixture.runtime.install(plan: next) { _ in
                if fixture.runtime.isRuntimeInstalled(next.runtime) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; XCTFail("Expected late cancellation") }
        catch is CancellationError { }
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(next.runtime))
        XCTAssertFalse(fixture.runtime.phoneExists(next.runtime))
        XCTAssertTrue(fixture.runtime.phoneExists(.legacy))
        XCTAssertEqual(try fixture.runtime.missingDownloadBytes(for: next), 0)
        try assertNoStaging(fixture.root)
        _ = try await fixture.runtime.install(plan: next) { _ in }
        XCTAssertTrue(fixture.runtime.phoneExists(next.runtime))
        await assertCalls(fixture.calls, downloads: 4)
    }

    func testPhoneCreationFailureKeepsCompletedImageForDownloadFreeRetry() async throws {
        let fixture = try fixture()
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        let next = plan(api: "37.0")
        let collision = fixture.runtime.avdHome.appendingPathComponent(next.runtime.deviceName + ".avd")
        do {
            _ = try await fixture.runtime.install(plan: next) { _ in
                if fixture.runtime.isRuntimeInstalled(next.runtime), !FileManager.default.fileExists(atPath: collision.path) {
                    try? FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
                    try? Data("external phone data".utf8).write(to: collision.appendingPathComponent("userdata.img"))
                }
            }
            XCTFail("A concurrently created phone must be preserved")
        } catch { XCTAssertEqual(error as? AndroidSetupError, .existingInstallation(collision.path)) }
        XCTAssertTrue(fixture.runtime.isRuntimeInstalled(next.runtime))
        XCTAssertTrue(fixture.runtime.phoneExists(.legacy))
        XCTAssertEqual(try String(contentsOf: collision.appendingPathComponent("userdata.img"), encoding: .utf8), "external phone data")
        XCTAssertEqual(try fixture.runtime.missingDownloadBytes(for: next), 0)
        try assertNoStaging(fixture.root)
        // Remove only the collision created by this test, then retry normally.
        try FileManager.default.removeItem(at: collision)
        _ = try await fixture.runtime.install(plan: next) { _ in }
        XCTAssertTrue(fixture.runtime.phoneExists(next.runtime))
        await assertCalls(fixture.calls, downloads: 4)
    }

    func testChecksumFailureRollsBackAndRetrySucceeds() async throws {
        let fixture = try fixture()
        var dependencies = fixture.dependencies
        dependencies.download = { package, url, _ in
            try Data(repeating: 0, count: Int(package.archiveBytes)).write(to: url)
        }
        do {
            _ = try await ManagedAndroidRuntime(root: fixture.root, dependencies: dependencies).install(plan: fixture.plan) { _ in }
            XCTFail("An altered download must not be installed")
        } catch {
            XCTAssertEqual(error as? AndroidSetupError, .checksumMismatch("emulator"))
        }
        await assertCalls(fixture.calls, extractions: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("sdk").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.device.path))
        try assertNoStaging(fixture.root)
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
        await assertCalls(fixture.calls, extractions: 3)
    }

    func testCancellationCleansDownloadsAndAllowsRetry() async throws {
        let fixture = try fixture()
        var dependencies = fixture.dependencies
        dependencies.download = { _, destination, _ in
            try Data("partial".utf8).write(to: destination)
            await fixture.calls.didDownload()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let runtime = ManagedAndroidRuntime(root: fixture.root, dependencies: dependencies)
        let task = Task { try await runtime.install(plan: fixture.plan) { _ in } }
        try await waitForDownload(fixture.calls)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("sdk").path))
        try assertNoStaging(fixture.root)
        _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }
    }

    func testSecondInstallerCannotEnterWhileFirstOwnsLock() async throws {
        let fixture = try fixture()
        var dependencies = fixture.dependencies
        dependencies.download = { _, _, _ in
            await fixture.calls.didDownload()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let runtime = ManagedAndroidRuntime(root: fixture.root, dependencies: dependencies)
        let task = Task { try await runtime.install(plan: fixture.plan) { _ in } }
        try await waitForDownload(fixture.calls)
        do { _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }; XCTFail("Expected installation lock") }
        catch { XCTAssertEqual(error as? AndroidSetupError, .installationInProgress) }
        task.cancel()
        _ = try? await task.value
    }

    func testInsufficientDiskSpaceFailsBeforeAnyDownload() async throws {
        let fixture = try fixture()
        var dependencies = fixture.dependencies
        dependencies.availableBytes = { _ in 4 * 1_024 * 1_024 * 1_024 }
        do {
            _ = try await ManagedAndroidRuntime(root: fixture.root, dependencies: dependencies).install(plan: fixture.plan) { _ in }
            XCTFail("Expected preflight failure")
        } catch {
            XCTAssertEqual(error as? AndroidSetupError, .insufficientSpace(required: 12 * 1_024 * 1_024 * 1_024,
                                                                           available: 4 * 1_024 * 1_024 * 1_024))
        }
        await assertCalls(fixture.calls, downloads: 0)
        try assertNoStaging(fixture.root)
    }

    func testUnownedSDKIsNeverOverwritten() async throws {
        let fixture = try fixture()
        let sdk = fixture.root.appendingPathComponent("sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let sentinel = sdk.appendingPathComponent("keep")
        try Data("my SDK".utf8).write(to: sentinel)
        do { _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }; XCTFail("Expected preservation refusal") }
        catch { XCTAssertEqual(error as? AndroidSetupError, .existingInstallation(sdk.path)) }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "my SDK")
        await assertCalls(fixture.calls, downloads: 0)
    }

    func testUnownedPhoneIsPreservedOnFailedSetup() async throws {
        let fixture = try fixture()
        try FileManager.default.createDirectory(at: fixture.device, withIntermediateDirectories: true)
        let sentinel = fixture.device.appendingPathComponent("userdata.img")
        try Data("my phone".utf8).write(to: sentinel)
        do { _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }; XCTFail("Expected preservation refusal") }
        catch { XCTAssertEqual(error as? AndroidSetupError, .existingInstallation(fixture.device.path)) }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "my phone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("sdk").path))
        try assertNoStaging(fixture.root)
    }

    func testSymlinkSDKCannotRedirectInstallationOutsideOwnedRoot() async throws {
        let fixture = try fixture()
        let outside = fixture.parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("sdk"), withDestinationURL: outside)
        do { _ = try await fixture.runtime.install(plan: fixture.plan) { _ in }; XCTFail("Expected preservation refusal") }
        catch is AndroidSetupError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        await assertCalls(fixture.calls, downloads: 0)
    }

    func testSHA1AndSHA256VerificationAndTruncatedDownload() throws {
        let fixture = try fixture()
        let archive = fixture.parent.appendingPathComponent("archive.zip")
        let bytes = Data("verified contents".utf8)
        try bytes.write(to: archive)
        for algorithm in ["sha1", "sha256"] {
            let package = package(id: "emulator", data: bytes, algorithm: algorithm)
            XCTAssertNoThrow(try ManagedAndroidRuntime.verify(archive: archive, package: package))
        }
        XCTAssertThrowsError(try ManagedAndroidRuntime.verify(archive: archive,
                                                            package: package(id: "emulator", data: bytes + Data([0]))))
    }

    func testUnsafeArchiveNamesAndSymlinkAncestorsAreRejectedBeforeExtraction() throws {
        for path in ["/emulator/file", "emulator/../outside", "emulator/./file", "emulator//file", "other/file",
                     "emulator/back\\slash", "emulator/file\nsecond", "emulator/\0file"] {
            XCTAssertThrowsError(try ManagedAndroidRuntime.validateArchiveEntries([.init(path: path, kind: 0o100000, size: 1)],
                                                                                  archiveRoot: "emulator"), path)
        }
        XCTAssertThrowsError(try ManagedAndroidRuntime.validateArchiveEntries([
            .init(path: "emulator/link", kind: 0o120000, size: 2),
            .init(path: "emulator/link/file", kind: 0o100000, size: 1)
        ], archiveRoot: "emulator"))
        XCTAssertThrowsError(try ManagedAndroidRuntime.validateArchiveEntries([
            .init(path: "emulator/file", kind: 0o100000, size: 1),
            .init(path: "emulator/file", kind: 0o100000, size: 1)
        ], archiveRoot: "emulator"))
        XCTAssertThrowsError(try ManagedAndroidRuntime.validateArchiveEntries([
            .init(path: "emulator/link/", kind: 0o120000, size: 2),
            .init(path: "emulator/link/file", kind: 0o100000, size: 1)
        ], archiveRoot: "emulator"))
    }

    func testExtractionInspectionAcceptsCanonicalAndAliasedParentPaths() throws {
        let fixture = try fixture()
        let extracted = fixture.parent.appendingPathComponent("unpacked")
        let package = extracted.appendingPathComponent("emulator")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: package.appendingPathComponent("emulator"))
        let alias = fixture.parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: extracted)
        XCTAssertNoThrow(try ManagedAndroidRuntime.validateExtractedTree(extracted, archiveRoot: "emulator"))
        XCTAssertNoThrow(try ManagedAndroidRuntime.validateExtractedTree(alias, archiveRoot: "emulator"))
    }

    func testRealZIPExtractionPreservesInternalSymlinkAndRejectsEscapingLink() async throws {
        let fixture = try fixture()
        let source = fixture.parent.appendingPathComponent("source/emulator")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: source.appendingPathComponent("binary"))
        let link = source.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "binary")
        for escaping in [false, true] {
            if escaping {
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../outside")
            }
            let archive = fixture.parent.appendingPathComponent("archive-\(escaping).zip")
            let zipped = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                                      arguments: ["-c", "-k", "--keepParent", "--norsrc", source.path, archive.path])
            try zipped.requireSuccess(operation: "Create ZIP fixture")
            let destination = fixture.parent.appendingPathComponent("extracted-\(escaping)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if escaping {
                do { try await ManagedAndroidRuntime.Dependencies.live.extract(archive, destination, "emulator"); XCTFail("Escaping link accepted") }
                catch is AndroidSetupError { }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
            } else {
                try await ManagedAndroidRuntime.Dependencies.live.extract(archive, destination, "emulator")
                try ManagedAndroidRuntime.validateExtractedTree(destination, archiveRoot: "emulator")
                XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("emulator/alias"), encoding: .utf8), "binary")
                var malformed = try Data(contentsOf: archive)
                // The first local filename starts at byte 30. Its corresponding
                // central-directory name remains unchanged.
                malformed[30] = UInt8(ascii: "/")
                let mismatch = fixture.parent.appendingPathComponent("name-mismatch.zip")
                try malformed.write(to: mismatch)
                XCTAssertThrowsError(try ZIPDirectory.read(mismatch))
            }
        }
    }

    private func fixture(modernImage: Bool = false) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DroidDock Setup Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Android")
        let installPlan = plan(api: "36")
        let calls = SetupCalls()
        let dependencies = ManagedAndroidRuntime.Dependencies(download: { package, destination, progress in
            await calls.didDownload()
            try Data(package.id.utf8).write(to: destination)
            progress(1)
        }, extract: { archive, directory, archiveRoot in
            await calls.didExtract()
            let id = try String(contentsOf: archive, encoding: .utf8)
            let root = directory.appendingPathComponent(archiveRoot)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let names = id == "emulator" ? ["emulator"] : id == "platform-tools" ? ["adb"]
                : ["system.img", modernImage ? "data/empty_data_disk" : "userdata.img", "ramdisk.img", "kernel-ranchu"]
            for name in names {
                let destination = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
        }, availableBytes: { _ in 100 * 1_024 * 1_024 * 1_024 })
        return Fixture(parent: parent, root: root, plan: installPlan, dependencies: dependencies, calls: calls)
    }

    private func plan(api: String, emulatorRevision: String = "37.1.11", minimumEmulator: String? = nil,
                      imageRevision: String = "7.0.0") -> AndroidInstallPlan {
        let version = AndroidRuntimeVersion(packageID: "system-images;android-\(api);google_apis;arm64-v8a")!
        let emulator = package(id: "emulator", data: Data("emulator".utf8), revision: emulatorRevision)
        let adb = package(id: "platform-tools", data: Data("platform-tools".utf8), revision: "37.0.0")
        let image = package(id: version.id, data: Data(version.id.utf8), revision: imageRevision,
                            dependencies: minimumEmulator.map { ["emulator": $0] } ?? [:])
        return AndroidInstallPlan(packages: [emulator, adb, image],
                                  licenses: [.init(id: "android-sdk-license", text: "\n Exact license terms.\n  Do not normalize. \n")],
                                  runtime: version)
    }

    private func package(id: String, data: Data, algorithm: String = "sha256", revision: String = "",
                         dependencies: [String: String] = [:]) -> AndroidSDKPackage {
        .init(id: id, displayName: id, archiveURL: URL(string: "https://dl.google.com/android/repository/fixture.zip")!,
              archiveBytes: Int64(data.count), checksum: digest(data, algorithm: algorithm), checksumType: algorithm,
              relativeInstallPath: id.replacingOccurrences(of: ";", with: "/"),
              archiveRoot: id.hasPrefix("system-images;") ? "arm64-v8a" : id,
              revision: revision, minimumDependencies: dependencies)
    }

    private func digest(_ data: Data, algorithm: String = "sha256") -> String {
        let hash = algorithm == "sha1" ? Array(Insecure.SHA1.hash(data: data)) : Array(SHA256.hash(data: data))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func assertNoStaging(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(files.contains(where: { $0.hasPrefix(".setup-") }), file: file, line: line)
    }

    private func assertCalls(_ calls: SetupCalls, downloads: Int? = nil, extractions: Int? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
        if let downloads {
            let actual = await calls.downloads
            XCTAssertEqual(actual, downloads, file: file, line: line)
        }
        if let extractions {
            let actual = await calls.extractions
            XCTAssertEqual(actual, extractions, file: file, line: line)
        }
    }

    private func waitForDownload(_ calls: SetupCalls) async throws {
        for _ in 0..<300 {
            if await calls.downloads > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RuntimeError.invalidArgument("Fixture download did not begin")
    }

    private struct Fixture: Sendable {
        let parent: URL
        let root: URL
        let plan: AndroidInstallPlan
        let dependencies: ManagedAndroidRuntime.Dependencies
        let calls: SetupCalls
        var runtime: ManagedAndroidRuntime { .init(root: root, dependencies: dependencies) }
        var device: URL { root.appendingPathComponent("avd/\(ManagedAndroidRuntime.deviceName).avd") }
    }

    private actor SetupCalls {
        var downloads = 0
        var extractions = 0
        func didDownload() { downloads += 1 }
        func didExtract() { extractions += 1 }
    }
}

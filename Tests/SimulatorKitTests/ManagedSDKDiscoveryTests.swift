import XCTest
@testable import SimulatorKit

final class ManagedSDKDiscoveryTests: XCTestCase {
    func testManagedFallbackRequiresCompletedInstallationMarker() throws {
        let root = try temporaryDirectory()
        let managed = root.appendingPathComponent("managed")
        let sdkRoot = managed.appendingPathComponent("sdk")
        try createSDK(at: sdkRoot)
        let home = root.appendingPathComponent("empty-home")

        XCTAssertThrowsError(try SDKLocator.resolve(explicitPath: nil, environment: [:],
                                                   homeDirectory: home, managedRoot: managed))
        try Data().write(to: sdkRoot.appendingPathComponent(SDKLocator.managedMarkerName))
        let sdk = try SDKLocator.resolve(explicitPath: nil, environment: [:],
                                         homeDirectory: home, managedRoot: managed)
        XCTAssertEqual(sdk.root, sdkRoot.resolvingSymlinksInPath())
        XCTAssertEqual(sdk.avdHome, managed.resolvingSymlinksInPath().appendingPathComponent("avd", isDirectory: true))
    }

    func testExistingSDKPrecedenceAndExplicitInvalidPathArePreserved() throws {
        let root = try temporaryDirectory()
        let managed = root.appendingPathComponent("managed")
        let managedSDK = managed.appendingPathComponent("sdk")
        let externalSDK = root.appendingPathComponent("external")
        try createSDK(at: managedSDK, managed: true)
        try createSDK(at: externalSDK)
        let environment = ["ANDROID_HOME": externalSDK.path]

        let external = try SDKLocator.resolve(explicitPath: nil, environment: environment,
                                              homeDirectory: root, managedRoot: managed)
        XCTAssertEqual(external.root, externalSDK.resolvingSymlinksInPath())
        XCTAssertNil(external.avdHome)
        XCTAssertNil(external.environmentOverrides["ANDROID_AVD_HOME"])
        let selected = try SDKLocator.resolve(explicitPath: managedSDK.path, environment: environment,
                                              homeDirectory: root, managedRoot: managed)
        XCTAssertNotNil(selected.avdHome)
        XCTAssertThrowsError(try SDKLocator.resolve(explicitPath: root.appendingPathComponent("missing").path,
                                                   environment: environment, homeDirectory: root, managedRoot: managed)) { error in
            guard case RuntimeError.invalidSDK = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testMarkerCannotInjectAnArbitraryAVDPath() throws {
        let root = try temporaryDirectory()
        let sdkRoot = root.appendingPathComponent("sdk")
        try createSDK(at: sdkRoot)
        let marker = sdkRoot.appendingPathComponent(SDKLocator.managedMarkerName)
        try Data("ANDROID_AVD_HOME=/some/external/folder".utf8).write(to: marker)
        let sdk = try SDKLocator.validate(path: sdkRoot.path)
        XCTAssertEqual(sdk.avdHome?.path, root.resolvingSymlinksInPath().appendingPathComponent("avd").path)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        XCTAssertNil(try SDKLocator.validate(path: sdkRoot.path).avdHome)
    }

    func testManagedDiscoveryReadsPrivateMetadataAndPassesAllAndroidLocations() async throws {
        let root = try temporaryDirectory()
        let sdkRoot = root.appendingPathComponent("sdk")
        let avdRoot = root.appendingPathComponent("avd")
        try createSDK(at: sdkRoot, managed: true, emulatorScript: """
        #!/bin/sh
        printf '%s\\n' "$ANDROID_HOME" "$ANDROID_SDK_ROOT" "$ANDROID_AVD_HOME" "$ANDROID_USER_HOME" "$ANDROID_EMULATOR_HOME" "$ANDROID_SDK_HOME" > "$ANDROID_AVD_HOME/discovery-environment"
        printf '%s\\n' 'DroidDock_Phone_API_36'
        """)
        let content = avdRoot.appendingPathComponent("DroidDock_Phone_API_36.avd")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("target=android-36\n".utf8).write(to: avdRoot.appendingPathComponent("DroidDock_Phone_API_36.ini"))
        try Data("avd.ini.displayname=DroidDock Phone\nabi.type=arm64-v8a\nhw.lcd.width=1080\nhw.lcd.height=1920\n".utf8)
            .write(to: content.appendingPathComponent("config.ini"))

        let sdk = try SDKLocator.validate(path: sdkRoot.path)
        let avds = try await AVDRepository.discover(sdk: sdk)
        XCTAssertEqual(avds.count, 1)
        XCTAssertEqual(avds.first?.displayName, "DroidDock Phone")
        XCTAssertEqual(avds.first?.apiLevel, "36")
        XCTAssertEqual(avds.first?.resolution, "1080 × 1920")
        XCTAssertEqual(avds.first?.configURL?.path, content.resolvingSymlinksInPath().appendingPathComponent("config.ini").path)
        let received = try String(contentsOf: avdRoot.appendingPathComponent("discovery-environment"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let paths = ["ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_USER_HOME", "ANDROID_EMULATOR_HOME", "ANDROID_SDK_HOME"]
        XCTAssertEqual(received, paths.compactMap { sdk.environmentOverrides[$0] })
    }

    func testRunnerOverridesInheritedEnvironmentWithoutChangingParent() async throws {
        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
                                                environmentOverrides: ["PATH": "/fixture-path", "DROIDDOCK_FIXTURE": "present"])
        try result.requireSuccess(operation: "Environment fixture")
        let lines = Set(result.text.split(separator: "\n").map(String.init))
        XCTAssertTrue(lines.contains("PATH=/fixture-path"))
        XCTAssertTrue(lines.contains("DROIDDOCK_FIXTURE=present"))
        XCTAssertTrue(lines.contains("LC_ALL=en_US.UTF-8"))
        XCTAssertEqual(ProcessInfo.processInfo.environment["PATH"], originalPath)
    }

    func testLaunchAndADBUseManagedEnvironment() async throws {
        let root = try temporaryDirectory()
        let sdkRoot = root.appendingPathComponent("sdk")
        let avdRoot = root.appendingPathComponent("avd")
        try FileManager.default.createDirectory(at: avdRoot, withIntermediateDirectories: true)
        try createSDK(at: sdkRoot, managed: true, emulatorScript: "#!/bin/sh\nexec /bin/sleep 30\n")
        try writeExecutable("""
        #!/bin/sh
        printf '%s\\n' "$ANDROID_AVD_HOME" > "$ANDROID_AVD_HOME/adb-environment"
        printf 'List of devices attached\\n'
        """, at: sdkRoot.appendingPathComponent("platform-tools/adb"))
        let sdk = try SDKLocator.validate(path: sdkRoot.path)
        let manager = EmulatorProcessManager(logDirectory: root.appendingPathComponent("logs"))
        let runtime = try await manager.launch(sdk: sdk, avd: AVD(name: "DroidDock_Phone_API_36"))
        for (key, value) in sdk.environmentOverrides {
            XCTAssertEqual(runtime.process.environment?[key], value, "Launch must use \(key)")
        }
        await manager.stop(runtime)
        XCTAssertFalse(runtime.process.isRunning)
        let adbEnvironment = try String(contentsOf: avdRoot.appendingPathComponent("adb-environment"), encoding: .utf8)
        XCTAssertEqual(adbEnvironment.trimmingCharacters(in: .whitespacesAndNewlines), sdk.avdHome?.path)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-sdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func createSDK(at root: URL, managed: Bool = false, emulatorScript: String = "#!/bin/sh\nexit 0\n") throws {
        try writeExecutable(emulatorScript, at: root.appendingPathComponent("emulator/emulator"))
        try writeExecutable("#!/bin/sh\nprintf 'List of devices attached\\n'\n", at: root.appendingPathComponent("platform-tools/adb"))
        if managed { try Data().write(to: root.appendingPathComponent(SDKLocator.managedMarkerName)) }
    }

    private func writeExecutable(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

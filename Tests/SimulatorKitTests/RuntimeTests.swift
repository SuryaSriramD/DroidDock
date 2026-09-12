import XCTest
@testable import SimulatorKit

final class RuntimeTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SimulatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testExplicitInvalidSDKDoesNotSilentlyFallBack() throws {
        let root = try temporaryDirectory()
        XCTAssertThrowsError(try SDKLocator.resolve(explicitPath: root.path)) { error in
            guard case RuntimeError.invalidSDK(let path, let missing) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(path, root.resolvingSymlinksInPath().path)
            XCTAssertEqual(missing, "emulator/emulator")
        }
    }

    func testSDKRequiresBothExecutableComponents() throws {
        let root = try temporaryDirectory()
        for component in ["emulator/emulator", "platform-tools/adb"] {
            let file = root.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let sdk = try SDKLocator.validate(path: root.path)
        XCTAssertEqual(sdk.adb.lastPathComponent, "adb")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sdk.adb.path)
        XCTAssertThrowsError(try SDKLocator.validate(path: root.path))
    }

    func testMetadataFollowsAVDIndexWithoutModifyingFiles() throws {
        let directory = try temporaryDirectory()
        let content = directory.appendingPathComponent("separate device folder")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let index = "path=\(content.path)\ntarget=android-35\n"
        let config = """
        # Preserve values containing equals signs.
        avd.ini.displayname=Pixel Test
        abi.type=arm64-v8a
        hw.lcd.width=1080
        hw.lcd.height=2400
        hw.ramSize=2048
        custom=value=with=equals
        """
        try Data(index.utf8).write(to: directory.appendingPathComponent("Test.ini"))
        let configURL = content.appendingPathComponent("config.ini")
        try Data(config.utf8).write(to: configURL)
        let avd = AVDRepository.metadata(name: "Test", searchDirectories: [directory])
        XCTAssertEqual(avd.displayName, "Pixel Test")
        XCTAssertEqual(avd.apiLevel, "35")
        XCTAssertEqual(avd.resolution, "1080 × 2400")
        XCTAssertEqual(avd.memoryMB, 2048)
        XCTAssertEqual(AVDRepository.readINI(at: configURL)["custom"], "value=with=equals")
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), config)
    }

    func testDeviceParsingKeepsOfflineAndUnauthorizedDevices() {
        let parsed = ADBService.parseDevices("""
        * daemon started successfully
        List of devices attached
        emulator-5554 device product:sdk model:Pixel transport_id:1
        emulator-5556 offline transport_id:2
        phone-123 unauthorized usb:123
        """)
        XCTAssertEqual(parsed.map(\.serial), ["emulator-5554", "emulator-5556", "phone-123"])
        XCTAssertEqual(parsed.map(\.state), ["device", "offline", "unauthorized"])
    }

    func testRemoteShellTokensCannotBecomeCommands() async throws {
        let marker = try temporaryDirectory().appendingPathComponent("injected")
        let text = "it's $(touch \(marker.path)); a space\nand a newline"
        let arguments = ADBService.shellArguments(for: ["printf", "%s", text])
        // /bin/sh models the remote shell parser, using our quoted command.
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", arguments[1]])
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSessionTransitionGraphIncludesCancellationAndRecovery() {
        let allowed: [SessionState: Set<SessionState>] = [
            .idle: [.starting], .starting: [.booting, .failed, .stopping],
            .booting: [.connecting, .failed, .stopping],
            .connecting: [.running, .reconnecting, .failed, .stopping],
            .running: [.reconnecting, .stopping, .failed],
            .reconnecting: [.running, .failed, .stopping],
            .stopping: [.idle, .failed], .failed: [.starting, .idle]
        ]
        for state in SessionState.allCases {
            for next in SessionState.allCases {
                XCTAssertEqual(state.canTransition(to: next), allowed[state]!.contains(next), "\(state) → \(next)")
            }
        }
    }

    func testLaunchIsHeadlessAndPreservesQuickBootByDefault() throws {
        let avd = AVD(name: "Pixel_Test")
        let normal = try EmulatorProcessManager.launchArguments(avd: avd, consolePort: 5554)
        XCTAssertEqual(Array(normal.suffix(2)), ["-gpu", "host"])
        XCTAssertTrue(normal.contains("-no-window"))
        XCTAssertFalse(normal.contains("-wipe-data"))
        XCTAssertFalse(normal.contains("-no-snapshot-load"))
        let cold = try EmulatorProcessManager.launchArguments(avd: avd, consolePort: 5556, coldBoot: true)
        XCTAssertTrue(cold.contains("-no-snapshot-load"))
        XCTAssertFalse(cold.contains("-wipe-data"))
        XCTAssertFalse(AVDRepository.isValidName("../../other"))
    }

    func testGraphicsModeAllowsExplicitRecoveryWithoutArbitraryArguments() throws {
        let avd = AVD(name: "Pixel_Test")
        for mode in ["host", "auto", "software"] {
            let arguments = try EmulatorProcessManager.launchArguments(avd: avd, consolePort: 5554, gpuMode: mode)
            XCTAssertEqual(Array(arguments.suffix(2)), ["-gpu", mode])
        }
        for invalid in ["", "host -wipe-data", "invalid", "Host"] {
            XCTAssertThrowsError(try EmulatorProcessManager.launchArguments(avd: avd, consolePort: 5554, gpuMode: invalid))
        }
    }

    func testWipeRequiresExplicitOptInAndAlwaysSkipsExistingSnapshots() throws {
        let avd = AVD(name: "Pixel_Test")
        for mode in ["host", "auto", "software"] {
            let normal = try EmulatorProcessManager.launchArguments(avd: avd, consolePort: 5560, gpuMode: mode)
            let noWipe = try EmulatorProcessManager.launchArguments(avd: avd, consolePort: 5560, gpuMode: mode, wipeData: false)
            XCTAssertEqual(normal, noWipe, "An omitted wipe option must preserve the existing safe default")
            XCTAssertFalse(normal.contains("-wipe-data"))
            XCTAssertFalse(normal.contains("-no-snapshot-load"))
            for coldBoot in [false, true] {
                let wipe = try EmulatorProcessManager.launchArguments(avd: avd, consolePort: 5560,
                    coldBoot: coldBoot, gpuMode: mode, wipeData: true)
                XCTAssertEqual(Array(wipe.prefix(7)), ["-avd", "Pixel_Test", "-no-window", "-port", "5560", "-gpu", mode])
                XCTAssertEqual(wipe.filter { $0 == "-wipe-data" }.count, 1)
                XCTAssertEqual(wipe.filter { $0 == "-no-snapshot-load" }.count, 1,
                               "Wipe must not resume an old snapshot, including when cold boot is also selected")
                XCTAssertFalse(wipe.contains("-no-snapshot-save"), "A clean guest may establish a new Quick Boot snapshot")
            }
            let cold = try EmulatorProcessManager.launchArguments(avd: avd, consolePort: 5560, coldBoot: true, gpuMode: mode)
            XCTAssertFalse(cold.contains("-wipe-data"), "Cold Boot is not authorization to erase user data")
            XCTAssertEqual(cold.filter { $0 == "-no-snapshot-load" }.count, 1)
        }
        XCTAssertThrowsError(try EmulatorProcessManager.launchArguments(avd: avd, consolePort: 5560,
            gpuMode: "host -wipe-data", wipeData: true), "Explicit wipe must not weaken option validation")
    }

    func testProcessCapturesBothPipesBeyondPipeBufferSize() async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print STDOUT 'o' x 262144; print STDERR 'e' x 262144; exit 7"], timeout: 5)
        XCTAssertEqual(result.stdout.count, 262_144)
        XCTAssertEqual(result.stderr.count, 262_144)
        XCTAssertEqual(result.status, 7)
        XCTAssertThrowsError(try result.requireSuccess(operation: "Fixture"))
    }

    func testProcessTimeoutReturnsPromptly() async throws {
        let started = Date()
        do {
            _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.1)
            XCTFail("Expected a timeout")
        } catch RuntimeError.commandTimedOut { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testProcessCancellationReturnsPromptly() async throws {
        let started = Date()
        let command = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        command.cancel()
        do { _ = try await command.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testUnboundedProcessOutputIsStopped() async throws {
        do {
            _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], timeout: 8)
            XCTFail("Expected output limit")
        } catch RuntimeError.outputLimitExceeded { }
    }

    func testManagerNeverStopsAnUnownedProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let unowned = RunningEmulator(process: process, serial: "emulator-5554", consolePort: 5554,
                                      avdName: "Pixel", logURL: URL(fileURLWithPath: "/dev/null"), id: UUID())
        await EmulatorProcessManager().stop(unowned)
        XCTAssertTrue(process.isRunning)
    }
}

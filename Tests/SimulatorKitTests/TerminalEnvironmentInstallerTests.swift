import Darwin
import XCTest
@testable import SimulatorKit

final class TerminalEnvironmentInstallerTests: XCTestCase {
    func testInstallationIsIdempotentAndPreservesProfilesWithBackups() throws {
        let fixture = try fixture()
        let original = "# my shell settings\nexport MY_SETTING='keep this'"
        for name in [".zshrc", ".bash_profile", ".bashrc"] {
            try Data(original.utf8).write(to: fixture.home.appendingPathComponent(name))
        }
        let first = try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk)
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.profileURLs.count, 3)
        XCTAssertEqual(first.backupURLs.count, 3)
        for backup in first.backupURLs { XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original) }
        for profile in first.profileURLs {
            let text = try String(contentsOf: profile, encoding: .utf8)
            XCTAssertTrue(text.hasPrefix(original + "\n"))
            XCTAssertEqual(text.components(separatedBy: TerminalEnvironmentInstaller.blockStart).count, 2)
        }
        let bytes = try first.profileURLs.map { try Data(contentsOf: $0) }
        let second = try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.backupURLs, [])
        XCTAssertEqual(try second.profileURLs.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path), fixture.cli.path)
        XCTAssertTrue(try String(contentsOf: first.environmentFile, encoding: .utf8).hasPrefix(TerminalEnvironmentInstaller.environmentMarker))
    }

    func testRealZshAndBashStartupResolveQuotedPathsAndManagedAndroidVariables() throws {
        let fixture = try fixture(name: "Home with spaces and 'quotes' $dollars `ticks`")
        try Data("export USER_STARTUP_MARKER='preserved'\n".utf8).write(to: fixture.home.appendingPathComponent(".zshrc"))
        try Data("export USER_STARTUP_MARKER='preserved'\n".utf8).write(to: fixture.home.appendingPathComponent(".bash_profile"))
        try Data("export USER_STARTUP_MARKER='preserved'\n".utf8).write(to: fixture.home.appendingPathComponent(".bashrc"))
        let installation = try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk)
        let script = """
        . \(quote(installation.environmentFile.path))
        . \(quote(installation.environmentFile.path))
        printf '%s\\n' "$(command -v droiddock)" "$(command -v adb)" "$(command -v emulator)"
        printf '%s\\n' "$ANDROID_HOME" "$ANDROID_AVD_HOME" "$ANDROID_USER_HOME" "$USER_STARTUP_MARKER" "$PATH"
        droiddock
        """
        for (shell, arguments) in [("/bin/zsh", ["-l", "-i", "-c"]), ("/bin/bash", ["--login", "-i", "-c"]), ("/bin/bash", ["-i", "-c"])] {
            let output = try run(shell, arguments: arguments + [script], fixture: fixture)
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(lines[0], fixture.link.path)
            XCTAssertEqual(lines[1], fixture.sdk.adb.path)
            XCTAssertEqual(lines[2], fixture.sdk.emulator.path)
            XCTAssertEqual(lines[3], fixture.sdk.root.path)
            XCTAssertEqual(lines[4], fixture.sdk.avdHome?.path)
            XCTAssertEqual(lines[5], fixture.sdk.environmentOverrides["ANDROID_USER_HOME"])
            XCTAssertEqual(lines[6], "preserved")
            let paths = lines[7].split(separator: ":").map(String.init)
            for path in [fixture.link.deletingLastPathComponent().path, fixture.sdk.adb.deletingLastPathComponent().path,
                         fixture.sdk.emulator.deletingLastPathComponent().path] {
                XCTAssertEqual(paths.filter { $0 == path }.count, 1, "Repeated sourcing duplicated \(path)")
            }
            XCTAssertEqual(lines[8], "fake-droiddock")
        }
    }

    func testBashUsesExistingLoginProfileWithoutShadowingIt() throws {
        for existing in [".bash_login", ".profile"] {
            let fixture = try fixture()
            try Data("export ORIGINAL_LOGIN='loaded'\n".utf8).write(to: fixture.home.appendingPathComponent(existing))
            let result = try fixture.installer.install(appBundle: fixture.app, sdk: nil)
            XCTAssertTrue(result.profileURLs.contains(fixture.home.appendingPathComponent(existing)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".bash_profile").path))
            let output = try run("/bin/bash", arguments: ["--login", "-c", "printf '%s\\n' \"$ORIGINAL_LOGIN\"; command -v droiddock"], fixture: fixture)
            XCTAssertEqual(output, "loaded\n\(fixture.link.path)\n")
        }
    }

    func testAbsoluteZdotdirIsUsedAndRelativeValueFallsBackToHome() throws {
        let fixture = try fixture()
        let dotDirectory = fixture.home.appendingPathComponent("custom zsh startup")
        let installer = TerminalEnvironmentInstaller(homeDirectory: fixture.home, environment: ["ZDOTDIR": dotDirectory.path])
        let result = try installer.install(appBundle: fixture.app, sdk: fixture.sdk)
        XCTAssertEqual(result.profileURLs.first, dotDirectory.appendingPathComponent(".zshrc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".zshrc").path))
        XCTAssertEqual(try run("/bin/zsh", arguments: ["-i", "-c", "command -v droiddock"], fixture: fixture,
                               extraEnvironment: ["ZDOTDIR": dotDirectory.path]), fixture.link.path + "\n")
        let relative = TerminalEnvironmentInstaller(homeDirectory: fixture.home, environment: ["ZDOTDIR": "relative"])
        XCTAssertEqual(try relative.install(appBundle: fixture.app, sdk: fixture.sdk).profileURLs.first,
                       fixture.home.appendingPathComponent(".zshrc"))
    }

    func testSDKSwitchUpdatesOwnedScriptAndNoSDKOnlyAddsCLIPath() throws {
        let fixture = try fixture()
        let first = try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk)
        let oldProfiles = try first.profileURLs.map { try Data(contentsOf: $0) }
        let otherRoot = fixture.home.appendingPathComponent("Other SDK")
        let other = try makeSDK(otherRoot, managed: false)
        let changed = try fixture.installer.install(appBundle: fixture.app, sdk: other)
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.backupURLs, [])
        XCTAssertEqual(try changed.profileURLs.map { try Data(contentsOf: $0) }, oldProfiles)
        XCTAssertEqual(try run("/bin/bash", arguments: ["--login", "-c", "printf '%s\\n' \"$ANDROID_HOME\"; command -v adb"], fixture: fixture),
                       other.root.path + "\n" + other.adb.path + "\n")
        let none = try fixture.installer.install(appBundle: fixture.app, sdk: nil)
        XCTAssertTrue(none.changed)
        let output = try run("/bin/bash", arguments: ["--login", "-c", "printf '%s\\n' \"${ANDROID_HOME-unset}\"; command -v droiddock"], fixture: fixture)
        XCTAssertEqual(output, "unset\n\(fixture.link.path)\n")
    }

    func testInheritedManagedPathIsMovedAheadOfOldSDKInUserStartup() throws {
        let fixture = try fixture()
        let old = try makeSDK(fixture.home.appendingPathComponent("Old SDK"), managed: false)
        let original = "export PATH=\(quote(old.adb.deletingLastPathComponent().path + ":" + old.emulator.deletingLastPathComponent().path)):\"$PATH\"\n"
        try Data(original.utf8).write(to: fixture.home.appendingPathComponent(".zshrc"))
        _ = try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk)
        let inherited = "/usr/bin:/bin:" + fixture.sdk.adb.deletingLastPathComponent().path + ":" + fixture.sdk.emulator.deletingLastPathComponent().path
        let output = try run("/bin/zsh", arguments: ["-i", "-c", "command -v adb; command -v emulator; printf '%s\\n' \"$PATH\""],
                             fixture: fixture, extraEnvironment: ["PATH": inherited])
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], fixture.sdk.adb.path)
        XCTAssertEqual(lines[1], fixture.sdk.emulator.path)
        let paths = lines[2].split(separator: ":").map(String.init)
        XCTAssertEqual(paths.first, fixture.sdk.adb.deletingLastPathComponent().path)
        XCTAssertEqual(paths.filter { $0 == fixture.sdk.adb.deletingLastPathComponent().path }.count, 1)
        XCTAssertTrue(paths.contains(old.adb.deletingLastPathComponent().path), "Unrelated user PATH entries must stay intact")
    }

    func testManagedToExternalSDKClearsOnlyStillOwnedInheritedAndroidVariables() throws {
        let fixture = try fixture()
        let managed = try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk)
        let saved = fixture.home.appendingPathComponent("managed-environment.sh")
        try FileManager.default.copyItem(at: managed.environmentFile, to: saved)
        let external = try makeSDK(fixture.home.appendingPathComponent("External SDK"), managed: false)
        let updated = try fixture.installer.install(appBundle: fixture.app, sdk: external)
        let customUserHome = fixture.home.appendingPathComponent("user-custom-android-home").path
        let script = """
        . \(quote(saved.path))
        export ANDROID_USER_HOME=\(quote(customUserHome))
        . \(quote(updated.environmentFile.path))
        printf '%s\\n' "$ANDROID_HOME" "${ANDROID_AVD_HOME-unset}" "${ANDROID_EMULATOR_HOME-unset}" "${ANDROID_SDK_HOME-unset}" "$ANDROID_USER_HOME"
        command -v adb
        """
        for shell in ["/bin/bash", "/bin/zsh"] {
            let output = try run(shell, arguments: ["-c", script], fixture: fixture)
            XCTAssertEqual(output, "\(external.root.path)\nunset\nunset\nunset\n\(customUserHome)\n\(external.adb.path)\n")
        }
    }

    func testDeletedAppOrSDKDoesNotExportDeadAndroidPaths() throws {
        for removeApp in [true, false] {
            let fixture = try fixture()
            _ = try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk)
            try FileManager.default.removeItem(at: removeApp ? fixture.cli : fixture.sdk.adb)
            let output = try run("/bin/bash", arguments: ["--login", "-c", "printf '%s\\n' \"${ANDROID_HOME-unset}\" \"${ANDROID_AVD_HOME-unset}\" \"$PATH\""], fixture: fixture)
            let lines = output.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines[0], "unset")
            XCTAssertEqual(lines[1], "unset")
            XCTAssertFalse(lines[2].split(separator: ":").contains(Substring(fixture.sdk.adb.deletingLastPathComponent().path)))
        }
    }

    func testConflictingCLIFilesAndLinksAbortBeforeProfileMutation() throws {
        for symbolic in [false, true] {
            let fixture = try fixture()
            try FileManager.default.createDirectory(at: fixture.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if symbolic { try FileManager.default.createSymbolicLink(atPath: fixture.link.path, withDestinationPath: "/some/other/tool") }
            else { try Data("my existing command".utf8).write(to: fixture.link) }
            let profile = fixture.home.appendingPathComponent(".zshrc")
            try Data("keep this shell config\n".utf8).write(to: profile)
            XCTAssertThrowsError(try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk)) {
                XCTAssertEqual($0 as? TerminalEnvironmentError, .unrelatedFile(fixture.link.path))
            }
            XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), "keep this shell config\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentFile.path))
        }
    }

    func testProfileSymlinkAndSpecialFileAbortWithoutFollowingThem() throws {
        for fifo in [false, true] {
            let fixture = try fixture()
            let profile = fixture.home.appendingPathComponent(".bashrc")
            let target = fixture.home.appendingPathComponent("unrelated-file")
            try Data("must stay untouched".utf8).write(to: target)
            if fifo { XCTAssertEqual(mkfifo(profile.path, 0o600), 0) }
            else { try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target) }
            XCTAssertThrowsError(try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk))
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "must stay untouched")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentFile.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.link.path))
        }
    }

    func testSystemAliasSupportDoesNotAllowUserControlledParentSymlinks() throws {
        let fixture = try fixture()
        let outside = fixture.home.appendingPathComponent("unrelated-directory")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let library = fixture.home.appendingPathComponent("Library")
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: outside)
        XCTAssertThrowsError(try fixture.installer.install(appBundle: fixture.app, sdk: fixture.sdk)) {
            XCTAssertEqual($0 as? TerminalEnvironmentError, .unsafeFile(library.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.link.path))
    }

    func testUnownedEnvironmentScriptAndMalformedManagedBlocksArePreserved() throws {
        let blocks = [TerminalEnvironmentInstaller.blockStart + "\nmissing end\n",
                      TerminalEnvironmentInstaller.blockEnd + "\n",
                      Array(repeating: TerminalEnvironmentInstaller.blockStart + "\nowned\n" + TerminalEnvironmentInstaller.blockEnd + "\n", count: 2).joined()]
        for block in blocks {
            let fixture = try fixture()
            let profile = fixture.home.appendingPathComponent(".zshrc")
            try Data(block.utf8).write(to: profile)
            XCTAssertThrowsError(try fixture.installer.install(appBundle: fixture.app, sdk: nil)) {
                XCTAssertEqual($0 as? TerminalEnvironmentError, .malformedBlock(profile.path))
            }
            XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), block)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentFile.path))
        }
        let fixture = try fixture()
        try FileManager.default.createDirectory(at: fixture.environmentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# This belongs to the user\n".utf8).write(to: fixture.environmentFile)
        XCTAssertThrowsError(try fixture.installer.install(appBundle: fixture.app, sdk: nil)) {
            XCTAssertEqual($0 as? TerminalEnvironmentError, .unrelatedFile(fixture.environmentFile.path))
        }
        XCTAssertEqual(try String(contentsOf: fixture.environmentFile, encoding: .utf8), "# This belongs to the user\n")
    }

    func testOwnedBlockIsUpdatedInPlaceWithoutChangingSurroundingTextOrPermissions() throws {
        let fixture = try fixture()
        let profile = fixture.home.appendingPathComponent(".zshrc")
        let prefix = "# prefix\r\nexport KEEP=before\r\n"
        let suffix = "export KEEP_AFTER=after\r\n# no trailing newline"
        let old = prefix + TerminalEnvironmentInstaller.blockStart + "\r\n# obsolete owned content\r\n" + TerminalEnvironmentInstaller.blockEnd + "\r\n" + suffix
        try Data(old.utf8).write(to: profile)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: profile.path)
        _ = try fixture.installer.install(appBundle: fixture.app, sdk: nil)
        let updated = try String(contentsOf: profile, encoding: .utf8)
        XCTAssertTrue(updated.hasPrefix(prefix)); XCTAssertTrue(updated.hasSuffix(suffix))
        XCTAssertFalse(updated.contains("obsolete owned content"))
        XCTAssertEqual(updated.components(separatedBy: TerminalEnvironmentInstaller.blockStart).count, 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber, NSNumber(value: 0o640))
    }

    func testConcurrentProfileEditRollsBackEarlierWritesAndPreservesNewContents() throws {
        let fixture = try fixture()
        let names = [".zshrc", ".bash_profile", ".bashrc"]
        for name in names { try Data("original \(name)\n".utf8).write(to: fixture.home.appendingPathComponent(name)) }
        let installer = TerminalEnvironmentInstaller(homeDirectory: fixture.home, environment: [:], beforeWrite: { url in
            if url.lastPathComponent == ".bashrc" { try Data("changed concurrently\n".utf8).write(to: url) }
        })
        XCTAssertThrowsError(try installer.install(appBundle: fixture.app, sdk: fixture.sdk)) {
            XCTAssertEqual($0 as? TerminalEnvironmentError, .changedDuringInstall(fixture.home.appendingPathComponent(".bashrc").path))
        }
        for name in names.prefix(2) {
            XCTAssertEqual(try String(contentsOf: fixture.home.appendingPathComponent(name), encoding: .utf8), "original \(name)\n")
        }
        XCTAssertEqual(try String(contentsOf: fixture.home.appendingPathComponent(".bashrc"), encoding: .utf8), "changed concurrently\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.link.path))
    }

    private func fixture(name: String = "Test Home") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Terminal Setup Tests-\(UUID().uuidString)")
        let home = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = home.appendingPathComponent("Applications/DroidDock's App.app")
        let cli = app.appendingPathComponent("Contents/MacOS/droiddock")
        try makeExecutable(cli, output: "fake-droiddock")
        let sdk = try makeSDK(home.appendingPathComponent("Android's SDK"), managed: true)
        return Fixture(home: home, app: app, sdk: sdk)
    }

    private func makeSDK(_ root: URL, managed: Bool) throws -> SDKInstallation {
        let adb = root.appendingPathComponent("platform-tools/adb")
        let emulator = root.appendingPathComponent("emulator/emulator")
        try makeExecutable(adb, output: "fake-adb")
        try makeExecutable(emulator, output: "fake-emulator")
        return SDKInstallation(root: root, emulator: emulator, adb: adb,
                               avdHome: managed ? root.deletingLastPathComponent().appendingPathComponent("private avd") : nil)
    }

    private func makeExecutable(_ url: URL, output: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '%s\\n' '\(output)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func run(_ shell: String, arguments: [String], fixture: Fixture,
                     extraEnvironment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.environment = ["HOME": fixture.home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]
            .merging(extraEnvironment) { _, value in value }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }

    private func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private struct Fixture: Sendable {
        let home: URL
        let app: URL
        let sdk: SDKInstallation
        var cli: URL { app.appendingPathComponent("Contents/MacOS/droiddock") }
        var link: URL { home.appendingPathComponent(".local/bin/droiddock") }
        var environmentFile: URL { home.appendingPathComponent("Library/Application Support/DroidDock/Terminal/environment.sh") }
        var installer: TerminalEnvironmentInstaller { .init(homeDirectory: home, environment: [:]) }
    }
}

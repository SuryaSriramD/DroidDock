import XCTest
@testable import SimulatorKit

final class EmulatorSnapshotsTests: XCTestCase {
    private let header = "ID        TAG                     VM SIZE                DATE       VM CLOCK"
    private let firstRow = "--        default_boot              0 B 2026-09-08 10:20:30   00:03:04.500"
    private let secondRow = "--        before-login_v2.1       1.5G 2026-09-08 11:25:31   01:04:05.600"

    func testParsesCompleteSnapshotTableAndPreservesMetadata() throws {
        let output = "List of snapshots present on all disks:\r\n\(header)\r\n\(firstRow)\r\n\(secondRow)\r\nOK\r\n"
        let snapshots = try parse(output)
        XCTAssertEqual(snapshots.map(\.name), ["default_boot", "before-login_v2.1"])
        XCTAssertEqual(snapshots.map(\.id), snapshots.map(\.name))
        XCTAssertEqual(snapshots[0].details, "0 B 2026-09-08 10:20:30   00:03:04.500")
    }

    func testAcceptsKnownEmptyListForms() throws {
        for output in ["OK\n", "\r\nOK\r\n", "There is no snapshot available.\nOK\n",
                       "There is no suitable snapshot available\nOK\n", "\(header)\nOK\n",
                       "List of snapshots present on all disks:\nNone\nOK\n"] {
            XCTAssertEqual(try parse(output), [], output)
        }
    }

    func testExcludesExplicitlyNonLoadablePartialSnapshots() throws {
        let output = """
        List of snapshots present on all disks:
        \(header)
        \(firstRow)

        List of partial (non-loadable) snapshots on 'userdata':
        \(header)
        2         partial_one               41M 2026-09-08 10:20:30 00:03:04.500

        List of partial (non-loadable) snapshots on 'cache':
        \(header)
        9         partial_one               41M 2026-09-08 10:20:30 00:03:04.500
        OK
        """
        XCTAssertEqual(try parse(output).map(\.name), ["default_boot"])
        XCTAssertEqual(try parse(output.replacingOccurrences(of: "\(header)\n\(firstRow)", with: "None")), [])
    }

    func testSupportsNumericIDsLongNamesAndInstructionCount() throws {
        let longName = String(repeating: "a", count: 128)
        let output = "Snapshot devices: userdata\nSnapshot list (from userdata):\n\(header) ICOUNT\n5 \(longName) 128 MiB 2026-09-08 10:20:30 120:03:04.500 400000\nOK\n"
        XCTAssertEqual(try parse(output).map(\.name), [longName])
    }

    func testRejectsUnknownTruncatedDuplicateAndUnsafeRows() throws {
        let malformed = ["", "Something changed\nOK\n", "\(header)\n\(firstRow)\n",
                         "List of snapshots present on all disks:\nOK\n", "Snapshot devices: userdata\nOK\n",
                         "\(header)\n-- only_a_name\nOK\n",
                         "\(header)\n\(firstRow)\n\(firstRow)\nOK\n",
                         "\(header)\n\(firstRow.replacingOccurrences(of: "default_boot", with: "../outside"))\nOK\n",
                         "\(header)\nNone\n\(firstRow)\nOK\n",
                         "\(header)\n\(firstRow)\nOK\nOK\n",
                         "List of partial (non-loadable) snapshots on 'userdata':\n\(header)\nOK\n"]
        for output in malformed {
            XCTAssertThrowsError(try parse(output), output) { error in
                guard case EmulatorSnapshotError.malformedResponse = error else {
                    return XCTFail("Expected malformed response, received \(error)")
                }
            }
        }
    }

    func testNameValidationTreatsNamesAsSingleConsoleTokens() throws {
        for name in ["default_boot", "_before-login.2", "123", String(repeating: "a", count: 128)] {
            XCTAssertTrue(EmulatorSnapshots.isValidName(name))
            XCTAssertNoThrow(try EmulatorSnapshots.validateName(name))
        }
        for name in ["", ".", "..", "-option", ".hidden", "two words", "name\nkill", "name\rkill",
                     "name\tkill", "../outside", "path/name", "name\\other", "a;b", "a&b", "$(kill)",
                     "`kill`", "'name'", "\"name\"", "a\0b", "café", String(repeating: "a", count: 129)] {
            XCTAssertFalse(EmulatorSnapshots.isValidName(name), name)
            XCTAssertThrowsError(try EmulatorSnapshots.validateName(name)) { error in
                XCTAssertEqual(error as? EmulatorSnapshotError, .invalidName)
            }
        }
    }

    func testKOOnEitherStreamOverridesExitZeroAndOK() throws {
        for stream in [false, true] {
            XCTAssertThrowsError(try EmulatorSnapshots.responseBody(stream ? "OK\n" : "KO: snapshot is corrupt\nOK\n",
                stderr: stream ? "KO: snapshot is corrupt\n" : "", operation: "load")) { error in
                XCTAssertEqual(error as? EmulatorSnapshotError, .consoleFailure(operation: "load", details: "KO: snapshot is corrupt"))
            }
        }
    }

    func testUnsupportedConsoleResponsesIncludeActionableAdvice() throws {
        for message in ["KO: unknown command, try 'help'", "KO: bad sub-command", "KO: currently unsupported",
                        "KO: Snapshot save is disabled because -read-only was specified",
                        "KO: Snapshot save is skipped. Reason: guest is offline",
                        "KO: No available block device supports snapshots"] {
            XCTAssertThrowsError(try EmulatorSnapshots.responseBody(message, operation: "save")) { error in
                XCTAssertEqual(error as? EmulatorSnapshotError, .unsupported(details: message))
                XCTAssertTrue(error.localizedDescription.contains("SDK Manager"))
            }
        }
    }

    func testAllCommandsUseExactSelectedSerialAndNeverRunImplicitly() async throws {
        let fixture = try fixture(stdout: "OK\n")
        let service = EmulatorSnapshots(adb: fixture.adb)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("commands").path))
        let empty = try await service.list()
        XCTAssertEqual(empty, [])
        try await service.save(name: "before-login.2")
        try await service.load(name: "before-login.2")
        try await service.delete(name: "before-login.2")
        XCTAssertEqual(try fixture.history(), [
            "-s\temulator-fixture\temu\tavd\tsnapshot\tlist",
            "-s\temulator-fixture\temu\tavd\tsnapshot\tsave\tbefore-login.2",
            "-s\temulator-fixture\temu\tavd\tsnapshot\tload\tbefore-login.2",
            "-s\temulator-fixture\temu\tavd\tsnapshot\tdelete\tbefore-login.2"])
    }

    func testInvalidNamesNeverReachADBForAnyMutation() async throws {
        let fixture = try fixture(stdout: "OK\n")
        let service = EmulatorSnapshots(adb: fixture.adb)
        for operation in ["save", "load", "delete"] {
            do {
                switch operation {
                case "save": try await service.save(name: "name\nkill")
                case "load": try await service.load(name: "name\nkill")
                default: try await service.delete(name: "name\nkill")
                }
                XCTFail("Invalid name should be rejected")
            } catch { XCTAssertEqual(error as? EmulatorSnapshotError, .invalidName) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("commands").path))
    }

    func testRealCommandBoundaryRejectsKOWithZeroOrNonzeroExitStatus() async throws {
        for status in [0, 1] {
            let fixture = try fixture(stdout: "KO: snapshot not found\n", status: status)
            do {
                try await EmulatorSnapshots(adb: fixture.adb).load(name: "missing")
                XCTFail("KO must fail even with status \(status)")
            } catch {
                guard case EmulatorSnapshotError.consoleFailure(let operation, let details) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(operation, "load")
                XCTAssertTrue(details.contains("snapshot not found"))
            }
            XCTAssertEqual(try fixture.history().count, 1, "A failed restore must never be retried automatically")
        }
    }

    func testBoundedTimeoutDoesNotRetryMutation() async throws {
        let fixture = try fixture(stdout: "OK\n", block: true)
        let service = EmulatorSnapshots(adb: fixture.adb, timeouts: .init(save: 1))
        let start = Date()
        do {
            try await service.save(name: "checkpoint")
            XCTFail("Blocked command should time out")
        } catch {
            XCTAssertEqual(error as? EmulatorSnapshotError, .timedOut(operation: "save", seconds: 1))
            XCTAssertTrue(error.localizedDescription.contains("may still be completing"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(try fixture.history().count, 1)
    }

    func testCancellationPropagatesWithoutFollowupCommands() async throws {
        let fixture = try fixture(stdout: "OK\n", block: true)
        let task = Task { try await EmulatorSnapshots(adb: fixture.adb).save(name: "checkpoint") }
        do { try await fixture.waitForCommand() }
        catch { task.cancel(); _ = try? await task.value; throw error }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        XCTAssertEqual(try fixture.history().count, 1)
    }

    private func parse(_ output: String) throws -> [EmulatorSnapshot] {
        try EmulatorSnapshots.parseListBody(EmulatorSnapshots.responseBody(output, operation: "list"))
    }

    private func fixture(stdout: String, stderr: String = "", status: Int = 0, block: Bool = false) throws -> SnapshotFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Snapshot Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("adb fixture")
        let script = #"""
        #!/usr/bin/perl
        use strict;
        use warnings;
        use File::Basename qw(dirname);
        my $root = dirname($0);
        open(my $history, '>>', "$root/commands") or die $!;
        print $history join("\t", @ARGV), "\n";
        close $history;
        while (-e "$root/block") { select undef, undef, undef, 0.01; }
        sub read_value {
          my ($name) = @_;
          open(my $input, '<', "$root/$name") or die $!;
          local $/;
          my $value = <$input>;
          close $input;
          return $value;
        }
        print read_value('stdout');
        print STDERR read_value('stderr');
        exit int(read_value('status'));
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        for (name, value) in [("stdout", stdout), ("stderr", stderr), ("status", String(status))] {
            try Data(value.utf8).write(to: root.appendingPathComponent(name))
        }
        if block { try Data().write(to: root.appendingPathComponent("block")) }
        return SnapshotFixture(root: root, adb: ADBService(sdk: SDKInstallation(root: root, emulator: executable, adb: executable), serial: "emulator-fixture"))
    }
}

private struct SnapshotFixture {
    let root: URL
    let adb: ADBService

    func history() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func waitForCommand() async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (try? history().isEmpty) == false { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RuntimeError.invalidArgument("Fixture command did not start")
    }
}

import XCTest
@testable import SimulatorKit

final class GuestRotationTests: XCTestCase {
    /// The executable models the public adb argument boundary and a persistent
    /// Android settings store. No Android device or emulator is started.
    private func fixture(auto: String?, rotation: String?, policy: String = "free") throws -> RotationFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Guest Rotation Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("adb fixture")
        let source = #"""
        #!/usr/bin/perl
        use strict;
        use warnings;
        use File::Basename qw(dirname);
        use Text::ParseWords qw(shellwords);
        my $root = dirname($0);
        die "wrong selected device" unless @ARGV == 4 && $ARGV[0] eq '-s'
          && $ARGV[1] eq 'emulator-fixture' && $ARGV[2] eq 'shell';
        my @command = shellwords($ARGV[3]);
        open(my $history, '>>', "$root/commands") or die $!;
        print $history join(' ', @command), "\n";
        close($history);
        sub write_value {
          my ($name, $value) = @_;
          open(my $output, '>', "$root/$name") or die $!;
          print $output $value;
          close($output);
        }
        sub read_value {
          my ($name) = @_;
          return 'null' unless -e "$root/$name";
          open(my $input, '<', "$root/$name") or die $!;
          local $/;
          my $value = <$input>;
          close($input);
          return $value;
        }
        sub marker {
          my ($name) = @_;
          open(my $output, '>', "$root/$name") or die $!;
          print $output 'ready';
          close($output);
        }
        sub block {
          my ($name) = @_;
          marker($name);
          while (!-e "$root/release") { select undef, undef, undef, 0.01; }
        }
        if ($command[0] eq 'wm' && $command[1] eq 'user-rotation') {
          if (@command > 2) {
            if ($command[2] eq 'free' && -e "$root/block-before-restore") {
              unlink "$root/block-before-restore";
              block('restore-blocked');
            }
            if (-e "$root/fail-all-writes") { print STDERR "fixture write unavailable\n"; exit 1; }
            if ($command[2] eq 'free' && -e "$root/fail-next-restore") {
              unlink "$root/fail-next-restore";
              print STDERR "fixture transient restore failure\n"; exit 1;
            }
          }
          if (@command == 2) { print read_value('policy'), "\n"; }
          elsif ($command[2] eq 'lock' && @command == 4 && $command[3] =~ /^[0-3]$/) {
            write_value('policy', "lock $command[3]");
            write_value('accelerometer_rotation', '0');
            write_value('user_rotation', $command[3]);
            if (-e "$root/block-after-lock") {
              unlink "$root/block-after-lock";
              block('lock-blocked');
            }
          } elsif ($command[2] eq 'free' && @command == 3) {
            write_value('policy', 'free');
            write_value('accelerometer_rotation', '1');
          } else { die "unsupported rotation action"; }
          exit 0;
        }
        my ($tool, $user_flag, $user, $verb, $namespace, $key, $value) = @command;
        die "unsupported command or user" unless $tool eq 'settings' && $user_flag eq '--user'
          && $user eq 'current' && $namespace eq 'system'
          && ($key eq 'accelerometer_rotation' || $key eq 'user_rotation');
        if ($verb ne 'get' && -e "$root/fail-all-writes") { print STDERR "fixture write unavailable\n"; exit 1; }
        my $file = "$root/$key";
        if ($verb eq 'get') {
          if ($key eq 'user_rotation' && -e "$root/block-before-read") {
            unlink "$root/block-before-read";
            block('read-blocked');
          }
          print read_value($key), "\n";
        } elsif ($verb eq 'put') {
          write_value($key, $value);
        } elsif ($verb eq 'delete') {
          unlink $file;
        } else { die "unsupported settings action"; }
        """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let fixture = RotationFixture(root: root,
            adb: ADBService(sdk: SDKInstallation(root: root, emulator: script, adb: script), serial: "emulator-fixture"))
        try fixture.set("accelerometer_rotation", auto)
        try fixture.set("user_rotation", rotation)
        try fixture.set("policy", policy)
        return fixture
    }

    func testRestoresOriginalSettingsAfterRepeatedRotationsAndStartsANewSnapshotNextTime() async throws {
        let fixture = try fixture(auto: "1", rotation: "2")
        let controller = GuestRotation(adb: fixture.adb)
        try await controller.prepare()
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "0")
        XCTAssertEqual(try fixture.value("user_rotation"), "2", "Preparing rotation must not choose a guest orientation itself")
        XCTAssertEqual(try fixture.value("policy"), "lock 2")

        try await controller.rotate(to: 1)
        XCTAssertEqual(try fixture.value("user_rotation"), "1")
        try await controller.rotate(to: 3)
        await controller.restore()
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "1")
        XCTAssertEqual(try fixture.value("user_rotation"), "2", "Repeated Rotate must preserve the pre-session orientation")
        XCTAssertEqual(try fixture.value("policy"), "free")

        let afterRestore = try fixture.history()
        await controller.restore()
        XCTAssertEqual(try fixture.history(), afterRestore, "Restoring an already restored controller must be a no-op")

        try fixture.set("accelerometer_rotation", "0")
        try fixture.set("user_rotation", "3")
        try fixture.set("policy", "lock 3")
        try await controller.rotate(to: 0)
        await controller.restore()
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "0")
        XCTAssertEqual(try fixture.value("user_rotation"), "3", "A later use must capture the new guest settings")
        XCTAssertEqual(try fixture.value("policy"), "lock 3")
    }

    func testOriginallyAbsentSettingsAreDeletedOnRestore() async throws {
        let fixture = try fixture(auto: nil, rotation: nil)
        let controller = GuestRotation(adb: fixture.adb)
        try await controller.prepare()
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "0")
        try await controller.rotate(to: 1)
        await controller.restore()
        XCTAssertNil(try fixture.value("accelerometer_rotation"))
        XCTAssertNil(try fixture.value("user_rotation"), "Absent values must remain absent, rather than becoming the literal string null")
        XCTAssertEqual(try fixture.value("policy"), "free")
    }

    func testCancelledPreparationBeforeSnapshotDoesNotChangeGuestSettings() async throws {
        let fixture = try fixture(auto: "1", rotation: "2")
        try fixture.mark("block-before-read")
        let controller = GuestRotation(adb: fixture.adb)
        let task = Task { try await controller.prepare() }
        do { try await fixture.waitForMarker("read-blocked") }
        catch { task.cancel(); _ = try? await task.value; throw error }
        task.cancel()
        do { try await task.value; XCTFail("Preparation should observe cancellation") }
        catch is CancellationError { }
        await controller.restore()
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "1")
        XCTAssertEqual(try fixture.value("user_rotation"), "2")
        XCTAssertEqual(try fixture.value("policy"), "free")
        XCTAssertFalse(try fixture.history().contains("wm user-rotation lock"), "An incomplete snapshot must not mutate Android rotation policy")
    }

    func testCancelledPreparationAfterGuestMutationRestoresEvenFromCancelledTask() async throws {
        let fixture = try fixture(auto: "1", rotation: "3")
        try fixture.mark("block-after-lock")
        let controller = GuestRotation(adb: fixture.adb)
        let task = Task {
            do { try await controller.prepare() }
            catch {
                // This models lifecycle cancellation after adb has applied the
                // setting but before it returns. Cleanup inherits cancellation.
                await controller.restore()
                throw error
            }
        }
        do { try await fixture.waitForMarker("lock-blocked") }
        catch { task.cancel(); _ = try? await task.value; throw error }
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "0", "Cancellation must occur after a real guest-side mutation")
        task.cancel()
        do { try await task.value; XCTFail("Preparation should observe cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "1")
        XCTAssertEqual(try fixture.value("user_rotation"), "3")
        XCTAssertEqual(try fixture.value("policy"), "free")
        let restoredHistory = try fixture.history()
        await controller.restore()
        XCTAssertEqual(try fixture.history(), restoredHistory)
    }

    func testInvalidRotationDoesNotReadOrMutateGuestState() async throws {
        let fixture = try fixture(auto: "1", rotation: "2")
        let controller = GuestRotation(adb: fixture.adb)
        for angle in [-1, 4, Int.max] {
            do { try await controller.rotate(to: angle); XCTFail("Expected rejection for angle \(angle)") }
            catch RuntimeError.invalidArgument { }
        }
        XCTAssertEqual(try fixture.history(), "")
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "1")
        XCTAssertEqual(try fixture.value("user_rotation"), "2")
        XCTAssertEqual(try fixture.value("policy"), "free")
    }

    func testTransientRestorationFailureRetriesTheWholeOrderedState() async throws {
        let fixture = try fixture(auto: "1", rotation: "2")
        let controller = GuestRotation(adb: fixture.adb)
        try await controller.rotate(to: 1)
        try fixture.mark("fail-next-restore")
        let restored = await controller.restore()
        XCTAssertTrue(restored)
        XCTAssertEqual(try fixture.value("policy"), "free")
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "1")
        XCTAssertEqual(try fixture.value("user_rotation"), "2")
        XCTAssertEqual(try fixture.history().components(separatedBy: "wm user-rotation free").count - 1, 2)
    }

    func testFailedRestorationRetainsOriginalForLaterRetry() async throws {
        let fixture = try fixture(auto: "1", rotation: "3")
        let controller = GuestRotation(adb: fixture.adb)
        try await controller.rotate(to: 1)
        try fixture.mark("fail-all-writes")
        let failed = await controller.restore()
        XCTAssertFalse(failed, "A failed restoration must be surfaced to its caller")
        XCTAssertEqual(try fixture.value("policy"), "lock 1")
        XCTAssertEqual(try fixture.value("user_rotation"), "1")
        XCTAssertEqual(try fixture.history().components(separatedBy: "wm user-rotation free").count - 1, 2, "A failed call must have bounded retries")
        try fixture.set("fail-all-writes", nil)
        let restored = await controller.restore()
        XCTAssertTrue(restored)
        XCTAssertEqual(try fixture.value("policy"), "free")
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "1")
        XCTAssertEqual(try fixture.value("user_rotation"), "3", "Retry must use the initial snapshot, not the currently overridden angle")
        let history = try fixture.history()
        let redundant = await controller.restore()
        XCTAssertTrue(redundant)
        XCTAssertEqual(try fixture.history(), history)
    }

    func testCancelledRestoreCompletesBeforeConcurrentRotationCapturesANewSnapshot() async throws {
        let fixture = try fixture(auto: "1", rotation: "2")
        let controller = GuestRotation(adb: fixture.adb)
        try await controller.rotate(to: 1)
        try fixture.mark("block-before-restore")
        let restoring = Task { await controller.restore() }
        do { try await fixture.waitForMarker("restore-blocked") }
        catch { try? fixture.mark("release"); _ = await restoring.value; throw error }
        restoring.cancel()
        let rotating = Task { try await controller.rotate(to: 3) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(try fixture.history().contains("wm user-rotation lock 3"), "New mutation must wait for in-flight restoration")
        try fixture.mark("release")
        let restored = await restoring.value
        XCTAssertTrue(restored, "Caller cancellation must not cancel guest cleanup")
        try await rotating.value
        XCTAssertEqual(try fixture.value("policy"), "lock 3", "An earlier cleanup must not overwrite the later requested angle")
        let restoredAgain = await controller.restore()
        XCTAssertTrue(restoredAgain)
        XCTAssertEqual(try fixture.value("policy"), "free")
        XCTAssertEqual(try fixture.value("accelerometer_rotation"), "1")
        XCTAssertEqual(try fixture.value("user_rotation"), "2", "The newer operation must capture the restored original state")
    }

    func testUnrecognizedOriginalPolicyPreventsAnUnrestorableOverride() async throws {
        let fixture = try fixture(auto: "1", rotation: "2", policy: "unsupported policy response")
        let controller = GuestRotation(adb: fixture.adb)
        do { try await controller.prepare(); XCTFail("An unrecognized policy must be rejected before mutation") }
        catch RuntimeError.invalidArgument { }
        XCTAssertFalse(try fixture.history().contains("wm user-rotation lock"))
        XCTAssertEqual(try fixture.value("policy"), "unsupported policy response")
        let restored = await controller.restore()
        XCTAssertTrue(restored)
    }
}

private struct RotationFixture {
    let root: URL
    let adb: ADBService

    func set(_ key: String, _ value: String?) throws {
        let file = root.appendingPathComponent(key)
        if let value { try Data(value.utf8).write(to: file, options: .atomic) }
        else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func value(_ key: String) throws -> String? {
        let file = root.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }

    func history() throws -> String {
        let file = root.appendingPathComponent("commands")
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    func mark(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }

    func waitForMarker(_ name: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RotationFixtureError.markerTimeout(name) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum RotationFixtureError: Error { case markerTimeout(String) }

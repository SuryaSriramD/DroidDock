import XCTest
import AVFoundation
import CoreVideo
@testable import SimulatorKit

final class ScreenRecordingTests: XCTestCase {
    private func fixture(validVideo: Bool = true) async throws -> RecordingFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Recording Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("source.mp4")
        if validVideo { try await Self.makeVideo(at: video) }
        else { try Data(repeating: 65, count: 512).write(to: video) }
        let script = root.appendingPathComponent("adb fixture")
        // This models the public selected-ADB boundary and virtual Android
        // process/files. It never signals a host process or accesses a device.
        let source = #"""
        #!/usr/bin/perl
        use strict; use warnings;
        use File::Basename qw(dirname);
        use File::Copy qw(copy);
        use Text::ParseWords qw(shellwords);
        use Time::HiRes qw(time sleep);
        my $root = dirname($0);
        die 'wrong selected device' unless @ARGV >= 4 && $ARGV[0] eq '-s' && $ARGV[1] eq 'emulator-fixture';
        my @command = $ARGV[2] eq 'shell' ? shellwords($ARGV[3]) : @ARGV[2..$#ARGV];
        open(my $history, '>>', "$root/commands") or die $!;
        print $history join(' ', @command), "\n"; close($history);
        sub write_value { my ($name,$value)=@_; open(my $f,'>',"$root/$name") or die $!; print $f $value; close($f); }
        sub value { my ($name)=@_; open(my $f,'<',"$root/$name") or die $!; local $/; my $s=<$f>; close($f); return $s; }
        if ($command[0] eq 'mkdir') {
          die 'unsafe remote directory' unless $command[1] eq '-m' && $command[2] eq '700' && $command[3] =~ m{^/data/local/tmp/android-simulator-recording-[a-f0-9-]{36}$};
          write_value('directory',$command[3]); write_value('owned-directory','1'); exit 0;
        }
        if ($command[0] eq 'sh' && $command[2] =~ /^umask 077;/) {
          my $script = $command[2]; my $dir = value('directory');
          die 'missing exact output' unless index($script,"'$dir/capture.mp4'") >= 0 && index($script,"'$dir/pid'") >= 0;
          my ($limit) = $script =~ /--time-limit (\d+)/;
          die 'unbounded recording' unless $limit >= 1 && $limit <= 180 && $script =~ /--bit-rate 8000000/;
          write_value('launch-requested','1');
          sleep 0.3 if -e "$root/delay-start";
          write_value('alive','1'); write_value('pid','4242');
          my $end = time + $limit;
          while (time < $end && !-e "$root/stop") { sleep 0.02; }
          copy("$root/source.mp4", "$root/remote.mp4") or die $!;
          unlink "$root/alive";
          print 'Recording complete'; exit 0;
        }
        if ($command[0] eq 'sh') {
          my $script = $command[2]; my $dir = value('directory');
          die 'missing ownership checks' unless index($script,'/proc/4242/stat') >= 0 && index($script,'12345') >= 0
            && index($script,'/system/bin/screenrecord') >= 0 && index($script,"'$dir/capture.mp4'") >= 0
            && index($script,'11111111-2222-3333-4444-555555555555') >= 0;
          if (-e "$root/disconnected") { print STDERR 'device offline'; exit 1; }
          exit 0 if -e "$root/pid-reused";
          exit 0 unless -e "$root/alive";
          if ($script =~ /kill -(INT|KILL) 4242$/) { write_value('stop',$1); }
          elsif ($script =~ /printf owned$/) { print 'owned'; }
          else { die 'unexpected script'; }
          exit 0;
        }
        if ($command[0] eq 'cat') {
          my $path = $command[1];
          if ($path eq '/proc/sys/kernel/random/boot_id') { print '11111111-2222-3333-4444-555555555555'; }
          elsif ($path =~ m{/pid$}) { exit 1 unless -e "$root/pid"; print value('pid'); }
          elsif ($path eq '/proc/4242/stat') { exit 1 unless -e "$root/alive"; print '4242 (screenrecord) S ', ('0 ' x 18), '12345 0 0'; }
          elsif ($path eq '/proc/4242/cmdline') { exit 1 unless -e "$root/alive"; print join("\0",'/system/bin/screenrecord','--verbose',value('directory').'/capture.mp4'),"\0"; }
          else { die 'unexpected cat'; }
          exit 0;
        }
        if ($command[0] eq 'stat') { print -e "$root/remote.mp4" ? -s "$root/remote.mp4" : 0; exit 0; }
        if ($command[0] eq 'pull') {
          die 'wrong pull path' unless $command[1] eq value('directory').'/capture.mp4';
          copy("$root/remote.mp4", $command[2]) or die $!; exit 0;
        }
        if ($command[0] eq 'rm') {
          die 'unsafe cleanup' unless @command == 4 && $command[1] eq '-f'
            && $command[2] eq value('directory').'/capture.mp4' && $command[3] eq value('directory').'/pid';
          die 'cleanup while process alive' if -e "$root/alive";
          unlink "$root/remote.mp4", "$root/pid"; exit 0;
        }
        if ($command[0] eq 'rmdir') {
          die 'wrong directory' unless @command == 2 && $command[1] eq value('directory');
          unlink "$root/owned-directory"; exit 0;
        }
        die 'unsupported command';
        """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return RecordingFixture(root: root, adb: ADBService(sdk: SDKInstallation(root: root, emulator: script, adb: script), serial: "emulator-fixture"))
    }

    func testFinishFinalizesDecodableVideoAndCleansOnlyOwnedResources() async throws {
        let fixture = try await fixture()
        try fixture.write("unrelated.mp4", "keep this file")
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("saved recording.mp4")
        try await recorder.start(to: destination, maximumDuration: 10)
        let result = try await recorder.finish()
        XCTAssertEqual(result.url, destination)
        XCTAssertEqual(result.width, 64); XCTAssertEqual(result.height, 96)
        XCTAssertGreaterThan(result.duration, 0)
        XCTAssertGreaterThan(result.byteCount, 32)
        XCTAssertNil(result.cleanupWarning)
        XCTAssertEqual(try fixture.read("stop"), "INT")
        XCTAssertEqual(try fixture.read("unrelated.mp4"), "keep this file")
        try fixture.assertClean()
        let repeated = try await recorder.finish()
        XCTAssertEqual(repeated.byteCount, result.byteCount)
        let cancelled = await recorder.cancel()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "Cancel after export must preserve the saved recording")
    }

    func testTimeLimitAutomaticallyExportsWithoutFinish() async throws {
        let fixture = try await fixture()
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("automatic.mp4")
        try await recorder.start(to: destination, maximumDuration: 1)
        let result = try await recorder.waitForCompletion()
        XCTAssertEqual(result.url, destination)
        XCTAssertFalse(fixture.exists("stop"), "Natural time limit needs no signal")
        try fixture.assertClean()
    }

    func testFinishWhileStartIsPreparingJoinsAndPreservesTheVideo() async throws {
        let fixture = try await fixture()
        try fixture.write("delay-start", "yes")
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("early stop.mp4")
        let starting = Task { try await recorder.start(to: destination, maximumDuration: 10) }
        try await fixture.waitFor("launch-requested")
        let result = try await recorder.finish()
        try await starting.value
        XCTAssertEqual(result.url, destination)
        try fixture.assertClean()
    }

    func testCancelledStartAwaitsOwnedProcessAndFileCleanup() async throws {
        let fixture = try await fixture()
        try fixture.write("delay-start", "yes")
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("cancelled.mp4")
        let starting = Task { try await recorder.start(to: destination, maximumDuration: 10) }
        try await fixture.waitFor("launch-requested")
        starting.cancel()
        do { try await starting.value; XCTFail("Cancelled start must throw") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try fixture.assertClean()
    }

    func testChangedApprovedDestinationIsPreserved() async throws {
        let fixture = try await fixture()
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("existing.mp4")
        try Data("original".utf8).write(to: destination)
        try await recorder.start(to: destination, maximumDuration: 10, overwriteExisting: true)
        // An unrelated writer atomically replaces the approved file while the
        // capture is in flight. Save approval must not extend to this new file.
        let replacement = Data("unrelated new document".utf8)
        try replacement.write(to: destination, options: .atomic)
        do { _ = try await recorder.finish(); XCTFail("Changed destination should reject export") }
        catch { XCTAssertTrue(error.localizedDescription.contains("destination changed")) }
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        try fixture.assertClean()
    }

    func testNewFileAtPreviouslyAbsentApprovedDestinationIsPreserved() async throws {
        let fixture = try await fixture()
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("appeared.mp4")
        try await recorder.start(to: destination, maximumDuration: 10, overwriteExisting: true)
        let replacement = Data("appeared during recording".utf8)
        try replacement.write(to: destination)
        do { _ = try await recorder.finish(); XCTFail("New destination should reject export") }
        catch { XCTAssertTrue(error.localizedDescription.contains("destination changed")) }
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        try fixture.assertClean()
    }

    func testUnchangedApprovedFileCanBeAtomicallyReplaced() async throws {
        let fixture = try await fixture()
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("replace.mp4")
        try Data("approved original".utf8).write(to: destination)
        try await recorder.start(to: destination, maximumDuration: 10, overwriteExisting: true)
        let result = try await recorder.finish()
        XCTAssertGreaterThan(result.byteCount, 32)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: fixture.root.appendingPathComponent("source.mp4")))
        try fixture.assertClean()
    }

    func testMalformedVideoIsNeverPublished() async throws {
        let fixture = try await fixture(validVideo: false)
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("invalid.mp4")
        try await recorder.start(to: destination, maximumDuration: 10)
        do { _ = try await recorder.finish(); XCTFail("Undecodable data must not be saved as a successful MP4") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try fixture.assertClean()
    }

    func testUnconfirmedRemoteExitIsReportedAndItsOutputIsNotUnlinked() async throws {
        let fixture = try await fixture()
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("disconnected.mp4")
        try await recorder.start(to: destination, maximumDuration: 10)
        try fixture.write("disconnected", "yes")
        let cleaned = await recorder.cancel()
        XCTAssertFalse(cleaned, "Cancellation must not claim cleanup succeeded when Android cannot confirm process exit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(fixture.exists("owned-directory"), "Do not unlink output while its remote writer may still be running")
        XCTAssertFalse(try fixture.read("commands").contains("rm -f"))
        do { _ = try await recorder.waitForCompletion(); XCTFail("Disconnected cleanup must report failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cleanup could not be confirmed")) }
    }

    func testReusedPIDIsNeverSignalled() async throws {
        let fixture = try await fixture()
        let recorder = ScreenRecording(adb: fixture.adb)
        let destination = fixture.root.appendingPathComponent("reused-pid.mp4")
        try await recorder.start(to: destination, maximumDuration: 1)
        // The virtual /proc ownership guard now represents a different process
        // at the same PID. It rejects both INT and KILL for that process.
        try fixture.write("pid-reused", "yes")
        _ = try await recorder.finish()
        XCTAssertFalse(fixture.exists("stop"))
        try fixture.assertClean()
    }

    func testInvalidDurationAndUnapprovedReplacementDoNotTouchADB() async throws {
        let fixture = try await fixture()
        let destination = fixture.root.appendingPathComponent("existing.mp4")
        for duration in [0, 181, Int.max] {
            do { try await ScreenRecording(adb: fixture.adb).start(to: destination, maximumDuration: duration); XCTFail("Unbounded duration accepted") } catch { }
        }
        try Data("keep".utf8).write(to: destination)
        do { try await ScreenRecording(adb: fixture.adb).start(to: destination); XCTFail("Unapproved replacement accepted") } catch { }
        XCTAssertFalse(fixture.exists("commands"))
    }

    func testIdentityRejectsAnUnrelatedRecordingProcess() {
        let stat = "4242 (screenrecord) S " + String(repeating: "0 ", count: 18) + "12345 0"
        let output = "/data/local/tmp/owned/capture.mp4"
        func command(_ executable: String, _ path: String) -> Data { Data((executable + "\0--verbose\0" + path + "\0").utf8) }
        XCTAssertNotNil(RecordingProcessIdentity(pid: 4242, stat: stat, command: command("/system/bin/screenrecord", output), expectedOutput: output))
        XCTAssertNil(RecordingProcessIdentity(pid: 4242, stat: stat, command: command("/system/bin/screenrecord", "/sdcard/unrelated.mp4"), expectedOutput: output))
        XCTAssertNil(RecordingProcessIdentity(pid: 4242, stat: stat, command: command("/system/bin/sh", output), expectedOutput: output))
        XCTAssertNil(RecordingProcessIdentity(pid: 4242, stat: "malformed", command: command("/system/bin/screenrecord", output), expectedOutput: output))
    }

    private static func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 96])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 96])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordingFixtureError.video }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<10 {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !input.isReadyForMoreMediaData {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw RecordingFixtureError.video }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var optional: CVPixelBuffer?
            guard let pool = adapter.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess,
                  let buffer = optional else { throw RecordingFixtureError.video }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(index * 20), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else { throw writer.error ?? RecordingFixtureError.video }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecordingFixtureError.video }
    }
}

private struct RecordingFixture {
    let root: URL
    let adb: ADBService
    func write(_ name: String, _ value: String) throws { try Data(value.utf8).write(to: root.appendingPathComponent(name)) }
    func read(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func waitFor(_ name: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !exists(name) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RecordingFixtureError.markerTimeout(name) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func assertClean(file: StaticString = #filePath, line: UInt = #line) throws {
        for name in ["alive", "owned-directory", "remote.mp4", "pid"] { XCTAssertFalse(exists(name), "Leaked \(name)", file: file, line: line) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".android-simulator-recording-") }, file: file, line: line)
    }
}

private enum RecordingFixtureError: Error { case video, markerTimeout(String) }

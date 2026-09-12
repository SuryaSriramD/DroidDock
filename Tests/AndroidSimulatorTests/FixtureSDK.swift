import Foundation
import SimulatorKit

/// Temporary SDK command contracts backed by ordinary Perl children. There is
/// no call to an installed SDK executable, Android runtime or host UI.
struct FixtureSDK: Sendable {
    let root: URL
    let installation: SDKInstallation

    init(avdName: String = "Fixture_AVD") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Controller Tests-\(UUID().uuidString)")
        let sdk = root.appendingPathComponent("sdk")
        let emulator = sdk.appendingPathComponent("emulator/emulator")
        let adb = sdk.appendingPathComponent("platform-tools/adb")
        for directory in [emulator.deletingLastPathComponent(), adb.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        installation = SDKInstallation(root: sdk, emulator: emulator, adb: adb)
        try Data(avdName.utf8).write(to: root.appendingPathComponent("avd-name"))
        for (url, source) in [(emulator, Self.emulator), (adb, Self.adb)] {
            try Data((Self.prelude + source).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func mark(_ name: String) throws { try Data("1".utf8).write(to: root.appendingPathComponent(name)) }
    func remove(_ name: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
    func pid(_ name: String) throws -> Int32 {
        let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return pid
    }
    func launchCount() throws -> Int {
        guard exists("launches") else { return 0 }
        return try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").count
    }
    func snapshotCommands() throws -> [String] {
        guard exists("snapshot-commands") else { return [] }
        return try String(contentsOf: root.appendingPathComponent("snapshot-commands"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private static let prelude = #"""
    #!/usr/bin/perl
    use strict;
    use warnings;
    use File::Basename qw(dirname);
    use Text::ParseWords qw(shellwords);
    $| = 1;
    my $root = dirname(dirname(dirname($0)));
    my $deadline = time() + 35;
    sub write_value {
      my ($name, $value) = @_;
      open(my $out, '>', "$root/$name") or die $!;
      print $out $value;
      close $out;
    }
    sub read_value {
      my ($name) = @_;
      return '' unless -e "$root/$name";
      open(my $in, '<', "$root/$name") or die $!;
      local $/;
      my $value = <$in>;
      close $in;
      return $value;
    }
    sub pause_tick {
      exit 0 if -e "$root/shutdown" || time() > $deadline;
      select undef, undef, undef, 0.01;
    }
    sub runtime_alive {
      my $pid = read_value('runtime-pid');
      return $pid =~ /^[0-9]+$/ && !-e "$root/runtime-terminated" && kill(0, int($pid));
    }

    """#

    private static let emulator = #"""
    if (@ARGV == 1 && $ARGV[0] eq '-version') { print "Android emulator version 37.1.11.0 fixture\n"; exit 0; }
    if (@ARGV == 1 && $ARGV[0] eq '-list-avds') {
      if (-e "$root/block-list") {
        write_value('list-blocked', '1');
        while (-e "$root/block-list") { pause_tick(); }
      }
      print read_value('avd-name'), "\n";
      exit 0;
    }
    my ($port, $avd);
    for (my $i = 0; $i < @ARGV - 1; $i++) {
      $port = $ARGV[$i + 1] if $ARGV[$i] eq '-port';
      $avd = $ARGV[$i + 1] if $ARGV[$i] eq '-avd';
    }
    die 'Unexpected fixture runtime arguments' unless defined $port && $port =~ /^[0-9]+$/ && defined $avd && $avd eq 'Fixture_AVD';
    unlink "$root/runtime-terminated";
    write_value('runtime-pid', $$);
    write_value('runtime-port', $port);
    open(my $launches, '>>', "$root/launches") or die $!;
    print $launches "$$\n";
    close $launches;
    $SIG{TERM} = sub {
      my $logcat = read_value('logcat-pid');
      if ($logcat =~ /^[0-9]+$/ && kill(0, int($logcat))) { write_value('runtime-stopped-with-live-logcat', '1'); }
      write_value('runtime-terminated', '1');
      exit 0;
    };
    while (1) {
      if (-e "$root/exit-runtime") { print STDERR "fixture-runtime-failure-42\n"; exit 42; }
      pause_tick();
    }
    """#

    private static let adb = #"""
    if (@ARGV == 1 && $ARGV[0] eq 'version') { print "Android Debug Bridge version 1.0.41 fixture\n"; exit 0; }
    if (@ARGV >= 1 && $ARGV[0] eq 'devices') {
      if (-e "$root/block-discovery") {
        write_value('discovery-pid', $$);
        write_value('discovery-blocked', '1');
        $SIG{TERM} = sub {};
        while (-e "$root/block-discovery") { pause_tick(); }
      }
      print "List of devices attached\n";
      if (runtime_alive()) { print 'emulator-', read_value('runtime-port'), "\tdevice\n"; }
      exit 0;
    }
    die 'Selected serial missing' unless @ARGV >= 3 && shift(@ARGV) eq '-s';
    my $serial = shift @ARGV;
    my $port = read_value('runtime-port');
    die 'Wrong selected serial' unless $serial eq "emulator-$port";
    if ($ARGV[0] eq 'get-state') { print(-e "$root/adb-offline" ? "offline\n" : "device\n"); exit 0; }
    if ($ARGV[0] eq 'emu' && @ARGV == 3 && $ARGV[1] eq 'avd' && $ARGV[2] eq 'name') { print "Fixture_AVD\nOK\n"; exit 0; }
    if ($ARGV[0] eq 'emu' && @ARGV == 5 && $ARGV[1] eq 'avd' && $ARGV[2] eq 'snapshot' &&
        $ARGV[3] eq 'save' && -e "$root/exit-during-snapshot") {
      write_value('snapshot-command-started', '1');
      write_value('exit-runtime', '1');
      while (runtime_alive()) { pause_tick(); }
      print STDERR "fixture snapshot lost its runtime\n";
      exit 91;
    }
    if ($ARGV[0] eq 'emu' && @ARGV == 4 && $ARGV[1] eq 'avd' && $ARGV[2] eq 'snapshot' && $ARGV[3] eq 'list') {
      open(my $commands, '>>', "$root/snapshot-commands") or die $!;
      print $commands "$serial list\n";
      close $commands;
      if (-e "$root/snapshot-unsupported") { print "KO: Snapshots are disabled for this fixture\n"; exit 0; }
      if (-e "$root/snapshot-failure") { print "KO: Temporary snapshot operation failure\n"; exit 0; }
      print "There is no snapshot available.\nOK\n";
      exit 0;
    }
    if ($ARGV[0] eq 'shell' && @ARGV == 2) {
      my @command = shellwords($ARGV[1]);
      if (@command == 2 && $command[0] eq 'getprop' && $command[1] eq 'sys.boot_completed') { print "1\n"; exit 0; }
    }
    if ($ARGV[0] eq 'logcat') {
      write_value('logcat-pid', $$);
      $SIG{TERM} = sub {
        write_value('logcat-term', '1');
        exit 0 unless -e "$root/logcat-ignore-term";
      };
      print "09-08 12:00:00.000 100 100 I Fixture: selected-device log\n";
      while (1) { pause_tick(); }
    }
    print STDERR 'Unexpected fixture ADB command: ', join(' ', @ARGV), "\n";
    exit 90;
    """#
}

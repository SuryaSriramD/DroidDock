import Darwin
import XCTest
@testable import SimulatorKit

final class AVDConfigurationTests: XCTestCase {
    func testLoadUsesLastDuplicateAndProvidesDefaultsForMissingSettings() throws {
        let fixture = try fixture("# Existing phone\nhw.ramSize=3072\nhw.ramSize = 4096\ncustom=value\n")
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        XCTAssertEqual(document.url, fixture.url)
        XCTAssertEqual(document.configuration, AVDConfiguration(displayName: "Fixture phone", memoryMB: 4096))
        XCTAssertEqual(try fixture.contents(), fixture.original)
    }

    func testSaveUpdatesAllFieldsWhilePreservingCommentsOrderUnknownKeysAndDiskFiles() throws {
        let original = """
        # Keep this comment
        avd.ini.displayname=Old phone
        image.sysdir.1=system-images/android-36/google_apis/arm64-v8a/
        hw.ramSize=2048
        hw.cpu.ncore=4
        ; This belongs here
        hw.lcd.width=1080
        hw.lcd.height=2400
        hw.lcd.density=420
        abi.type=arm64-v8a
        disk.dataPartition.size=4G
        custom.future.flag=yes
        """
        let fixture = try fixture(original)
        let disk = fixture.root.appendingPathComponent("userdata-qemu.img")
        try Data("keep all installed apps".utf8).write(to: disk)
        let snapshot = fixture.root.appendingPathComponent("snapshots/default_boot/ram.bin")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep saved snapshot".utf8).write(to: snapshot)
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        let edited = AVDConfiguration(displayName: "Work phone", memoryMB: 4096, cpuCores: 8,
                                      width: 1440, height: 2560, density: 560)
        try AVDConfigurationStore.save(edited, document: document)
        let expected = original.replacingOccurrences(of: "=Old phone", with: "=Work phone")
            .replacingOccurrences(of: "hw.ramSize=2048", with: "hw.ramSize=4096")
            .replacingOccurrences(of: "hw.cpu.ncore=4", with: "hw.cpu.ncore=8")
            .replacingOccurrences(of: "hw.lcd.width=1080", with: "hw.lcd.width=1440")
            .replacingOccurrences(of: "hw.lcd.height=2400", with: "hw.lcd.height=2560")
            .replacingOccurrences(of: "hw.lcd.density=420", with: "hw.lcd.density=560")
        XCTAssertEqual(try fixture.contents(), expected)
        XCTAssertEqual(try AVDConfigurationStore.load(avd: fixture.avd).configuration, edited)
        XCTAssertEqual(try String(contentsOf: disk, encoding: .utf8), "keep all installed apps")
        XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "keep saved snapshot")
    }

    func testNoOpDoesNotRewriteBytesPermissionsOrInode() throws {
        let fixture = try fixture("avd.ini.displayname = Fixture phone\r\nhw.ramSize=02048\r\n# exact formatting\r\n")
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        let before = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        try AVDConfigurationStore.save(document.configuration, document: document)
        let after = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        XCTAssertEqual(try fixture.contents(), fixture.original)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testDisplayNameOnlyEditDoesNotMaterializeMissingSettings() throws {
        let fixture = try fixture("# Incomplete legacy configuration\ncustom = untouched\navd.ini.displayname=Old")
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        var edited = document.configuration
        edited.displayName = "New"
        try AVDConfigurationStore.save(edited, document: document)
        XCTAssertEqual(try fixture.contents(), "# Incomplete legacy configuration\ncustom = untouched\navd.ini.displayname=New")
    }

    func testChangedMissingKeyIsAppendedUsingExistingLineEnding() throws {
        let fixture = try fixture("# CRLF configuration\r\ncustom=yes")
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        var edited = document.configuration
        edited.cpuCores = 6
        try AVDConfigurationStore.save(edited, document: document)
        XCTAssertEqual(try fixture.contents(), "# CRLF configuration\r\ncustom=yes\r\nhw.cpu.ncore=6\r\n")
    }

    func testEveryDuplicateOfEditedKeyChangesWithOriginalSpacingPreserved() throws {
        let fixture = try fixture("hw.ramSize = 1024  \n  hw.ramSize=02048\n# hw.ramSize=leave comment\nhw.cpu.ncore = 04\n")
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        var edited = document.configuration
        edited.memoryMB = 4096
        try AVDConfigurationStore.save(edited, document: document)
        XCTAssertEqual(try fixture.contents(), "hw.ramSize = 4096  \n  hw.ramSize=4096\n# hw.ramSize=leave comment\nhw.cpu.ncore = 04\n")
    }

    func testInvalidInputCannotChangeOriginalFile() throws {
        let fixture = try fixture("avd.ini.displayname=Original\nhw.ramSize=2048\n")
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        var variants: [AVDConfiguration] = []
        for name in ["", " \t ", "Phone\nhw.ramSize=16384", "Phone\rInjected", "Phone\0Injected", String(repeating: "a", count: 129)] {
            var value = document.configuration; value.displayName = name; variants.append(value)
        }
        var value = document.configuration; value.memoryMB = 511; variants.append(value)
        value = document.configuration; value.memoryMB = 16385; variants.append(value)
        value = document.configuration; value.cpuCores = 0; variants.append(value)
        value = document.configuration; value.cpuCores = 17; variants.append(value)
        value = document.configuration; value.width = 0; variants.append(value)
        value = document.configuration; value.width = 1081; variants.append(value)
        value = document.configuration; value.height = 2401; variants.append(value)
        value = document.configuration; value.height = 4098; variants.append(value)
        value = document.configuration; value.density = 119; variants.append(value)
        value = document.configuration; value.density = 641; variants.append(value)
        for invalid in variants {
            XCTAssertNotNil(invalid.validationError)
            XCTAssertThrowsError(try AVDConfigurationStore.save(invalid, document: document))
            XCTAssertEqual(try fixture.contents(), fixture.original)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["config.ini"])
    }

    func testExternalEditIsNotOverwrittenEvenForNoOpSave() throws {
        let fixture = try fixture("avd.ini.displayname=Original\n")
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        try Data("avd.ini.displayname=Changed elsewhere\n".utf8).write(to: fixture.url)
        XCTAssertThrowsError(try AVDConfigurationStore.save(document.configuration, document: document)) {
            XCTAssertEqual($0 as? AVDConfigurationError, .changedOnDisk)
        }
        XCTAssertEqual(try fixture.contents(), "avd.ini.displayname=Changed elsewhere\n")
    }

    func testFileReplacementWithIdenticalBytesAlsoRequiresReopening() throws {
        let fixture = try fixture("avd.ini.displayname=Original\n")
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        let replacement = fixture.root.appendingPathComponent("replacement")
        try Data(fixture.original.utf8).write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, fixture.url.path), 0)
        var edited = document.configuration; edited.displayName = "New"
        XCTAssertThrowsError(try AVDConfigurationStore.save(edited, document: document)) {
            XCTAssertEqual($0 as? AVDConfigurationError, .changedOnDisk)
        }
        XCTAssertEqual(try fixture.contents(), fixture.original)
    }

    func testSymlinkIsRejectedAtLoadAndWhenSwappedInAfterOpening() throws {
        let fixture = try fixture("avd.ini.displayname=Original\n")
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        let target = fixture.root.appendingPathComponent("untouched.ini")
        try Data("external file".utf8).write(to: target)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)
        XCTAssertThrowsError(try AVDConfigurationStore.load(avd: fixture.avd)) {
            XCTAssertEqual($0 as? AVDConfigurationError, .unsafeFile)
        }
        var edited = document.configuration; edited.displayName = "New"
        XCTAssertThrowsError(try AVDConfigurationStore.save(edited, document: document))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external file")
    }

    func testOversizedNonUTF8AndMalformedNumericFilesAreRejected() throws {
        for data in [Data(repeating: 65, count: 1_048_577), Data([0xff, 0xfe]), Data("hw.ramSize=oops\n".utf8)] {
            let fixture = try fixture("")
            try data.write(to: fixture.url)
            XCTAssertThrowsError(try AVDConfigurationStore.load(avd: fixture.avd))
            XCTAssertEqual(try Data(contentsOf: fixture.url), data)
        }
        XCTAssertThrowsError(try AVDConfigurationStore.load(avd: AVD(name: "Missing"))) {
            XCTAssertEqual($0 as? AVDConfigurationError, .missingConfiguration)
        }
    }

    func testDirectoryAndFIFOAreRejectedWithoutBlocking() throws {
        let fixture = try fixture("")
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AVDConfigurationStore.load(avd: fixture.avd)) {
            XCTAssertEqual($0 as? AVDConfigurationError, .unsafeFile)
        }
        try FileManager.default.removeItem(at: fixture.url)
        XCTAssertEqual(mkfifo(fixture.url.path, 0o600), 0)
        XCTAssertThrowsError(try AVDConfigurationStore.load(avd: fixture.avd)) {
            XCTAssertEqual($0 as? AVDConfigurationError, .unsafeFile)
        }
    }

    func testReadOnlyConfigurationRefusesSaveAndAtomicReplacementPreservesPermissions() throws {
        let fixture = try fixture("avd.ini.displayname=Original\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fixture.url.path)
        var document = try AVDConfigurationStore.load(avd: fixture.avd)
        var edited = document.configuration; edited.displayName = "New"
        XCTAssertThrowsError(try AVDConfigurationStore.save(edited, document: document)) {
            XCTAssertEqual($0 as? AVDConfigurationError, .notWritable)
        }
        XCTAssertEqual(try fixture.contents(), fixture.original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.url.path)
        document = try AVDConfigurationStore.load(avd: fixture.avd)
        try AVDConfigurationStore.save(edited, document: document)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o640)
    }

    func testUnrecognizedFileAndDirectoryMarkersBlockSaveWithoutRemovingLockOrChangingData() throws {
        for name in ["hardware-qemu.ini.lock", "userdata-qemu.img.lock", "snapshot.lock.lock"] {
            for directory in [false, true] {
                let fixture = try fixture("avd.ini.displayname=Original\n")
                let document = try AVDConfigurationStore.load(avd: fixture.avd)
                let lock = fixture.root.appendingPathComponent(name)
                if directory { try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false) }
                else { try Data("12345".utf8).write(to: lock) }
                var edited = document.configuration; edited.displayName = "New"
                XCTAssertThrowsError(try AVDConfigurationStore.save(edited, document: document)) {
                    XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
                }
                XCTAssertThrowsError(try AVDConfigurationStore.load(avd: fixture.avd))
                XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
                XCTAssertEqual(try fixture.contents(), fixture.original)
            }
        }
    }

    func testDeadOwnerMarkersAllowLoadAndSaveWithoutRemovingMarkersOrPhoneData() throws {
        let pid = try deadOwnerPID()
        for name in ["hardware-qemu.ini.lock", "userdata-qemu.img.lock", "snapshot.lock.lock"] {
            let fixture = try fixture("avd.ini.displayname=Original\n")
            let lock = fixture.root.appendingPathComponent(name)
            let marker = Data("\(pid)\0".utf8)
            try marker.write(to: lock)
            let dataURL = fixture.root.appendingPathComponent("userdata-qemu.img")
            try Data("retained phone data".utf8).write(to: dataURL)
            let document = try AVDConfigurationStore.load(avd: fixture.avd)
            var edited = document.configuration; edited.displayName = "Updated"

            try AVDConfigurationStore.save(edited, document: document)

            XCTAssertEqual(try fixture.contents(), "avd.ini.displayname=Updated\n")
            XCTAssertEqual(try Data(contentsOf: lock), marker)
            XCTAssertEqual(try Data(contentsOf: dataURL), Data("retained phone data".utf8))
        }
    }

    func testLiveOwnerBlocksEveryPIDMarkerEvenWithoutKernelLocks() throws {
        for name in ["hardware-qemu.ini.lock", "userdata-qemu.img.lock", "snapshot.lock.lock"] {
            let fixture = try fixture("avd.ini.displayname=Original\n")
            let document = try AVDConfigurationStore.load(avd: fixture.avd)
            let lock = fixture.root.appendingPathComponent(name)
            let marker = Data("\(ProcessInfo.processInfo.processIdentifier)\0".utf8)
            try marker.write(to: lock)
            var edited = document.configuration; edited.displayName = "Rejected"
            XCTAssertThrowsError(try AVDConfigurationStore.load(avd: fixture.avd)) {
                XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
            }
            XCTAssertThrowsError(try AVDConfigurationStore.save(edited, document: document)) {
                XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
            }
            XCTAssertEqual(try fixture.contents(), fixture.original)
            XCTAssertEqual(try Data(contentsOf: lock), marker)
        }
    }

    func testMalformedOrUnsupportedOwnerRecordsRemainBlocked() throws {
        let pid = try deadOwnerPID()
        let records = [Data(), Data([0]), Data("\(pid)".utf8), Data("\(pid)\n".utf8),
                       Data("0\0".utf8), Data("-1\0".utf8), Data("+\(pid)\0".utf8),
                       Data(" \(pid)\0".utf8), Data("0\(pid)\0".utf8),
                       Data("\(pid)\0suffix".utf8), Data("\(pid)\0\0".utf8),
                       Data("2147483648\0".utf8), Data(repeating: 49, count: 64), Data([255, 0])]
        for record in records {
            let fixture = try fixture("avd.ini.displayname=Original\n")
            let lock = fixture.root.appendingPathComponent("hardware-qemu.ini.lock")
            try record.write(to: lock)
            XCTAssertThrowsError(try AVDConfigurationStore.load(avd: fixture.avd)) {
                XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
            }
            XCTAssertEqual(try Data(contentsOf: lock), record)
            XCTAssertEqual(try fixture.contents(), fixture.original)
        }
    }

    func testSymlinkAndFIFOMarkersAreRejectedWithoutFollowingOrBlocking() throws {
        let pid = try deadOwnerPID()
        for symlink in [true, false] {
            let fixture = try fixture("avd.ini.displayname=Original\n")
            let lock = fixture.root.appendingPathComponent("hardware-qemu.ini.lock")
            let target = fixture.root.appendingPathComponent("other-marker")
            let bytes = Data("\(pid)\0".utf8)
            try bytes.write(to: target)
            if symlink { try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target) }
            else { XCTAssertEqual(mkfifo(lock.path, 0o600), 0) }
            XCTAssertThrowsError(try AVDConfigurationStore.requireStoppedDevice(at: fixture.url)) {
                XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
            }
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        }
    }

    func testDeadPIDDoesNotOverrideHeldFlock() throws {
        let pid = try deadOwnerPID()
        for name in ["hardware-qemu.ini.lock", "userdata-qemu.img.lock", "snapshot.lock.lock"] {
            let fixture = try fixture("avd.ini.displayname=Original\n")
            let lock = fixture.root.appendingPathComponent(name)
            let marker = Data("\(pid)\0".utf8)
            try marker.write(to: lock)
            let descriptor = Darwin.open(lock.path, O_RDWR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try AVDConfigurationStore.requireStoppedDevice(at: fixture.url)) {
                XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
            }
            XCTAssertEqual(try Data(contentsOf: lock), marker)
        }
    }

    func testDeadPIDDoesNotOverrideHeldPOSIXRecordLock() async throws {
        let fixture = try fixture("avd.ini.displayname=Original\n")
        let lock = fixture.root.appendingPathComponent("hardware-qemu.ini.lock")
        let marker = Data("\(try deadOwnerPID())\0".utf8)
        try marker.write(to: lock)
        try await withHeldPOSIXLock(at: lock) {
            XCTAssertThrowsError(try AVDConfigurationStore.requireStoppedDevice(at: fixture.url)) {
                XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
            }
        }
        try AVDConfigurationStore.requireStoppedDevice(at: fixture.url)
        XCTAssertEqual(try Data(contentsOf: lock), marker)
    }

    func testMarkerAcquiringLiveOwnerOrReplacedBySymlinkAfterLoadBlocksSave() throws {
        let pid = try deadOwnerPID()
        for symlink in [false, true] {
            let fixture = try fixture("avd.ini.displayname=Original\n")
            let lock = fixture.root.appendingPathComponent("hardware-qemu.ini.lock")
            try Data("\(pid)\0".utf8).write(to: lock)
            let document = try AVDConfigurationStore.load(avd: fixture.avd)
            if symlink {
                let moved = fixture.root.appendingPathComponent("moved-marker")
                try FileManager.default.moveItem(at: lock, to: moved)
                try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: moved)
            } else {
                try Data("\(ProcessInfo.processInfo.processIdentifier)\0".utf8).write(to: lock)
            }
            var edited = document.configuration; edited.displayName = "Rejected"
            XCTAssertThrowsError(try AVDConfigurationStore.save(edited, document: document)) {
                XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
            }
            XCTAssertEqual(try fixture.contents(), fixture.original)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        }
    }

    func testPersistentUnlockedMultiinstanceFileDoesNotBlockStoppedPhone() throws {
        let fixture = try fixture("avd.ini.displayname=Original\n")
        let lock = fixture.root.appendingPathComponent("multiinstance.lock")
        try Data().write(to: lock)
        let document = try AVDConfigurationStore.load(avd: fixture.avd)
        var edited = document.configuration; edited.displayName = "New"
        try AVDConfigurationStore.save(edited, document: document)
        XCTAssertEqual(try fixture.contents(), "avd.ini.displayname=New\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func testHeldMultiinstanceFlockBlocksMutation() throws {
        let fixture = try fixture("avd.ini.displayname=Original\n")
        let lock = fixture.root.appendingPathComponent("multiinstance.lock")
        let descriptor = Darwin.open(lock.path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try AVDConfigurationStore.requireStoppedDevice(at: fixture.url)) {
            XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
        }
    }

    func testHeldMultiinstancePOSIXRecordLockInAnotherProcessBlocksMutation() async throws {
        let fixture = try fixture("avd.ini.displayname=Original\n")
        let lock = fixture.root.appendingPathComponent("multiinstance.lock")
        try Data().write(to: lock)
        try await withHeldPOSIXLock(at: lock) {
            XCTAssertThrowsError(try AVDConfigurationStore.requireStoppedDevice(at: fixture.url)) {
                XCTAssertEqual($0 as? AVDConfigurationError, .deviceInUse)
            }
        }
    }

    private func deadOwnerPID() throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        let pid = child.processIdentifier
        guard pid > 0, kill(pid, 0) == -1, errno == ESRCH else {
            throw CocoaError(.executableRuntimeMismatch)
        }
        return pid
    }

    private func withHeldPOSIXLock(at lock: URL, operation: () throws -> Void) async throws {
        let ready = lock.deletingLastPathComponent().appendingPathComponent("ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl, pathlib, signal, sys\nsignal.alarm(15)\nf = open(sys.argv[1], 'r+')\nfcntl.lockf(f, fcntl.LOCK_EX)\npathlib.Path(sys.argv[2]).touch()\nsys.stdin.read(1)\n", lock.path, ready.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let result: Result<Void, Error>
        do {
            for _ in 0..<300 {
                if FileManager.default.fileExists(atPath: ready.path) { break }
                guard process.isRunning else {
                    XCTFail("Record-lock fixture exited before acquiring its lock")
                    throw CocoaError(.executableRuntimeMismatch)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard FileManager.default.fileExists(atPath: ready.path) else {
                XCTFail("Record-lock fixture did not become ready")
                throw CocoaError(.executableRuntimeMismatch)
            }
            try operation()
            result = .success(())
        } catch {
            result = .failure(error)
        }
        // A byte explicitly releases sys.stdin.read(1); pipe EOF and a blocking
        // waitUntilExit can stall Foundation's notification processing here.
        if process.isRunning { try? input.fileHandleForWriting.write(contentsOf: Data([10])) }
        try? input.fileHandleForWriting.close()
        await waitForFixtureExit(process, timeout: 2)
        if process.isRunning {
            process.terminate()
            await waitForFixtureExit(process, timeout: 0.5)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            await waitForFixtureExit(process, timeout: 2)
        }
        XCTAssertFalse(process.isRunning, "Record-lock fixture must finish its bounded cleanup")
        try result.get()
    }

    private func waitForFixtureExit(_ process: Process, timeout: TimeInterval) async {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            // Cleanup must also yield when its calling test task was cancelled.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
            }
        }
    }

    private func fixture(_ contents: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AVD Configuration Tests-\(UUID().uuidString).avd")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.ini")
        try Data(contents.utf8).write(to: url)
        return Fixture(root: root, url: url, original: contents)
    }

    private struct Fixture {
        let root: URL
        let url: URL
        let original: String
        var avd: AVD { AVD(name: "Fixture", displayName: "Fixture phone", configURL: url) }
        func contents() throws -> String { try String(contentsOf: url, encoding: .utf8) }
    }
}

import Foundation
import Darwin
import XCTest
@testable import SimulatorKit

final class RuntimeLedgerTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Runtime Ledger Tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func sdk(_ directory: URL) -> SDKInstallation {
        SDKInstallation(root: directory, emulator: URL(fileURLWithPath: "/bin/sleep"),
                        adb: directory.appendingPathComponent("platform tools/adb"))
    }

    private func entry(sdk: SDKInstallation, id: UUID = UUID(), pid: Int32 = 3210,
                       serial: String = "emulator-5554", avd: String = "Test_Device",
                       start: UInt64 = 100, executable: String = "/bin/sleep",
                       date: Date = Date()) -> RuntimeLedger.Entry {
        RuntimeLedger.Entry(runtimeID: id,
            process: .init(pid: pid, startSeconds: start, startMicroseconds: 22, executablePath: executable),
            serial: serial, avdName: avd,
            sdkRoot: sdk.root.standardizedFileURL.resolvingSymlinksInPath().path,
            sdkEmulator: sdk.emulator.standardizedFileURL.resolvingSymlinksInPath().path,
            sdkADB: sdk.adb.standardizedFileURL.resolvingSymlinksInPath().path,
            disposition: .running, recordedAt: date)
    }

    private func write(_ entries: [RuntimeLedger.Entry], to url: URL) throws {
        try JSONEncoder().encode(RuntimeLedger.Document(version: 1, entries: entries)).write(to: url)
    }

    func testNativeChildRoundTripDispositionExclusionAndRemoval() async throws {
        let directory = try temporaryDirectory(), installation = sdk(directory)
        let url = directory.appendingPathComponent("history.json")
        let process = Process()
        process.executableURL = installation.emulator
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let runtime = RunningEmulator(process: process, serial: "emulator-5554", consolePort: 5554,
            avdName: "Test_Device", logURL: directory.appendingPathComponent("unused.log"), id: UUID())
        let ledger = RuntimeLedger(url: url)
        try await ledger.record(runtime: runtime, sdk: installation)
        let devices = [ADBDevice(serial: runtime.serial, state: "device", avdName: runtime.avdName)]
        let matches = try await ledger.inspect(discovered: devices, sdk: installation)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.runtimeID, runtime.id)
        XCTAssertEqual(matches.first?.pid, process.processIdentifier)
        XCTAssertEqual(matches.first?.disposition, .running)
        XCTAssertEqual(matches.first?.executablePath, RuntimeLedger.nativeIdentity(process.processIdentifier)?.executablePath)
        let excluded = try await ledger.inspect(discovered: devices, sdk: installation, excludingRuntimeIDs: [runtime.id])
        XCTAssertTrue(excluded.isEmpty)
        try await ledger.markLeftRunning(id: runtime.id)
        let reopened = RuntimeLedger(url: url)
        let left = try await reopened.inspect(discovered: devices, sdk: installation)
        XCTAssertEqual(left.first?.disposition, .intentionallyLeftRunning)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("unused.log"))
        XCTAssertFalse(content.contains("arguments"))
        try await reopened.remove(id: runtime.id)
        let removed = try await ledger.inspect(discovered: devices, sdk: installation)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(process.isRunning, "Metadata inspection and removal must never stop or adopt the process")
    }

    func testNativeIdentityRejectsMissingPIDAndUsesProcessStartTime() {
        XCTAssertNil(RuntimeLedger.nativeIdentity(-1))
        XCTAssertNil(RuntimeLedger.nativeIdentity(Int32.max))
        let first = RuntimeLedger.nativeIdentity(getpid())
        let second = RuntimeLedger.nativeIdentity(getpid())
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first?.startSeconds ?? 0, 0)
        XCTAssertTrue(first?.executablePath.hasPrefix("/") == true)
    }

    func testReusedPIDExecChangeAndUnavailableProcessCannotMatch() async throws {
        let directory = try temporaryDirectory(), installation = sdk(directory)
        let url = directory.appendingPathComponent("history.json")
        let recorded = entry(sdk: installation)
        try write([recorded], to: url)
        let devices = [ADBDevice(serial: recorded.serial, state: "device", avdName: recorded.avdName)]
        let reused = RuntimeLedger(url: url) { pid in
            .init(pid: pid, startSeconds: recorded.process.startSeconds + 1,
                  startMicroseconds: recorded.process.startMicroseconds, executablePath: recorded.process.executablePath)
        }
        let afterExec = RuntimeLedger(url: url) { pid in
            .init(pid: pid, startSeconds: recorded.process.startSeconds,
                  startMicroseconds: recorded.process.startMicroseconds, executablePath: "/different/emulator")
        }
        let missing = RuntimeLedger(url: url) { _ in nil }
        for ledger in [reused, afterExec, missing] {
            let matches = try await ledger.inspect(discovered: devices, sdk: installation)
            XCTAssertTrue(matches.isEmpty)
        }
    }

    func testEverySDKAndDeviceIdentityComponentMustMatch() async throws {
        let directory = try temporaryDirectory(), installation = sdk(directory)
        let url = directory.appendingPathComponent("history.json")
        let recorded = entry(sdk: installation)
        try write([recorded], to: url)
        let ledger = RuntimeLedger(url: url) { _ in recorded.process }
        for device in [
            ADBDevice(serial: recorded.serial, state: "offline", avdName: recorded.avdName),
            ADBDevice(serial: recorded.serial, state: "device", avdName: nil),
            ADBDevice(serial: recorded.serial, state: "device", avdName: "Other_Device"),
            ADBDevice(serial: "emulator-5556", state: "device", avdName: recorded.avdName)
        ] {
            let matches = try await ledger.inspect(discovered: [device], sdk: installation)
            XCTAssertTrue(matches.isEmpty)
        }
        let devices = [ADBDevice(serial: recorded.serial, state: "device", avdName: recorded.avdName)]
        for changedSDK in [
            SDKInstallation(root: directory.appendingPathComponent("other"), emulator: installation.emulator, adb: installation.adb),
            SDKInstallation(root: installation.root, emulator: directory.appendingPathComponent("other"), adb: installation.adb),
            SDKInstallation(root: installation.root, emulator: installation.emulator, adb: directory.appendingPathComponent("other"))
        ] {
            let matches = try await ledger.inspect(discovered: devices, sdk: changedSDK)
            XCTAssertTrue(matches.isEmpty)
        }
        let before = try Data(contentsOf: url)
        let good = try await ledger.inspect(discovered: devices, sdk: installation)
        XCTAssertEqual(good.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), before, "Inspect is strictly read-only")
    }

    func testCorruptionIsActionablePreservedUntilExplicitRecovery() async throws {
        let directory = try temporaryDirectory(), installation = sdk(directory)
        let url = directory.appendingPathComponent("history.json")
        let damaged = Data("{\"version\":1,\"entries\":[".utf8)
        try damaged.write(to: url)
        let ledger = RuntimeLedger(url: url)
        do {
            _ = try await ledger.inspect(discovered: [], sdk: installation)
            XCTFail("Expected an explicit damaged-history error")
        } catch RuntimeLedger.Error.corruptLedger(let path) {
            XCTAssertEqual(path, url.path)
        }
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        do { try await ledger.markLeftRunning(id: UUID()); XCTFail("Do not silently overwrite corrupt history") }
        catch RuntimeLedger.Error.corruptLedger { }
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        try await ledger.resetCorruptLedger()
        let empty = try await ledger.inspect(discovered: [], sdk: installation)
        XCTAssertTrue(empty.isEmpty)
        do { try await ledger.resetCorruptLedger(); XCTFail("Valid history must not be reset") }
        catch RuntimeLedger.Error.ledgerIsNotCorrupt { }
    }

    func testOversizedAndMalformedIdentityFilesAreRejectedWithoutUnboundedRead() async throws {
        let directory = try temporaryDirectory(), installation = sdk(directory)
        let url = directory.appendingPathComponent("history.json")
        let ledger = RuntimeLedger(url: url)
        try Data(repeating: 32, count: RuntimeLedger.maximumFileBytes + 1).write(to: url)
        do { _ = try await ledger.inspect(discovered: [], sdk: installation); XCTFail("Expected size limit") }
        catch RuntimeLedger.Error.corruptLedger { }
        let invalid = entry(sdk: installation, pid: -1)
        try write([invalid], to: url)
        do { _ = try await ledger.inspect(discovered: [], sdk: installation); XCTFail("Expected invalid process identity") }
        catch RuntimeLedger.Error.corruptLedger { }
    }

    func testSymlinkAndSpecialFileAreNeverReadOrReplaced() async throws {
        let directory = try temporaryDirectory(), installation = sdk(directory)
        let target = directory.appendingPathComponent("keep.txt"), url = directory.appendingPathComponent("history.json")
        let contents = Data("do not alter".utf8)
        try contents.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let ledger = RuntimeLedger(url: url)
        do { _ = try await ledger.inspect(discovered: [], sdk: installation); XCTFail("Do not follow ledger symlinks") }
        catch RuntimeLedger.Error.inaccessibleLedger { }
        do { try await ledger.resetCorruptLedger(); XCTFail("Do not replace an inaccessible symlink") }
        catch RuntimeLedger.Error.inaccessibleLedger { }
        XCTAssertEqual(try Data(contentsOf: target), contents)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        let began = Date()
        do { _ = try await ledger.inspect(discovered: [], sdk: installation); XCTFail("Do not read a FIFO") }
        catch RuntimeLedger.Error.inaccessibleLedger { }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
    }

    func testConcurrentUpdatesAreSerializedAndBounded() async throws {
        let directory = try temporaryDirectory(), installation = sdk(directory)
        let url = directory.appendingPathComponent("history.json")
        let entries = (0..<RuntimeLedger.maximumEntries).map { index in
            entry(sdk: installation, pid: Int32(4000 + index), serial: "emulator-\(5554 + index * 2)")
        }
        try write(entries, to: url)
        let identities = Dictionary(uniqueKeysWithValues: entries.map { ($0.process.pid, $0.process) })
        let ledger = RuntimeLedger(url: url) { identities[$0] }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, value) in entries.enumerated() {
                group.addTask {
                    if index % 2 == 0 { try await ledger.remove(id: value.runtimeID) }
                    else { try await ledger.markLeftRunning(id: value.runtimeID) }
                }
            }
            try await group.waitForAll()
        }
        let devices = entries.map { ADBDevice(serial: $0.serial, state: "device", avdName: $0.avdName) }
        let matches = try await ledger.inspect(discovered: devices, sdk: installation)
        XCTAssertEqual(matches.count, RuntimeLedger.maximumEntries / 2)
        XCTAssertTrue(matches.allSatisfy { $0.disposition == .intentionallyLeftRunning })
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, RuntimeLedger.maximumFileBytes)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(siblings, [url.lastPathComponent], "Atomic writes must not accumulate temporary files")
    }

    func testRecordingAtCapacityKeepsNewestAndAtomicWriteFailureKeepsPriorHistory() async throws {
        let directory = try temporaryDirectory(), installation = sdk(directory)
        let url = directory.appendingPathComponent("history.json")
        let entries = (0..<RuntimeLedger.maximumEntries).map { index in
            entry(sdk: installation, pid: Int32(4000 + index), serial: "emulator-\(5554 + index * 2)",
                  date: Date(timeIntervalSince1970: Double(index + 1)))
        }
        try write(entries, to: url)
        let process = Process()
        process.executableURL = installation.emulator; process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let runtime = RunningEmulator(process: process, serial: "emulator-6000", consolePort: 6000,
            avdName: "Newest_Device", logURL: directory.appendingPathComponent("unused"), id: UUID())
        let ledger = RuntimeLedger(url: url)
        try await ledger.record(runtime: runtime, sdk: installation)
        let stored = try JSONDecoder().decode(RuntimeLedger.Document.self, from: Data(contentsOf: url))
        XCTAssertEqual(stored.entries.count, RuntimeLedger.maximumEntries)
        XCTAssertFalse(stored.entries.contains { $0.runtimeID == entries[0].runtimeID })
        XCTAssertTrue(stored.entries.contains { $0.runtimeID == runtime.id })
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        do { try await ledger.markLeftRunning(id: runtime.id); XCTFail("Expected write failure in read-only folder") }
        catch RuntimeLedger.Error.writeFailed { }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}

import XCTest
import Darwin
@testable import SimulatorKit

final class AVDDeletionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let sdk: SDKInstallation
        let avd: AVD
        let directory: URL
        let index: URL
        let config: URL
        let fakeTrash: URL
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AVDDeletion-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        let directory = avdHome.appendingPathComponent("Phone.avd", isDirectory: true)
        let sdkRoot = root.appendingPathComponent("sdk", isDirectory: true)
        let fakeTrash = root.appendingPathComponent("test-trash", isDirectory: true)
        for path in [directory, sdkRoot, fakeTrash] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let config = directory.appendingPathComponent("config.ini")
        let index = avdHome.appendingPathComponent("Phone.ini")
        try Data("avd.ini.displayname=My Phone\nhw.ramSize=2048\nabi.type=arm64-v8a\n".utf8).write(to: config)
        try Data("path=\(directory.path)\npath.rel=avd/Phone.avd\ntarget=android-36\n".utf8).write(to: index)
        try Data("guest apps and files".utf8).write(to: directory.appendingPathComponent("userdata-qemu.img"))
        try Data("shared SDK content".utf8).write(to: sdkRoot.appendingPathComponent("keep.txt"))
        let sdk = SDKInstallation(root: sdkRoot, emulator: sdkRoot.appendingPathComponent("emulator/emulator"),
                                  adb: sdkRoot.appendingPathComponent("platform-tools/adb"), avdHome: avdHome)
        let avd = AVDRepository.metadata(name: "Phone", searchDirectories: [avdHome])
        return Fixture(root: root, sdk: sdk, avd: avd, directory: directory, index: index, config: config, fakeTrash: fakeTrash)
    }

    private func moveToTestTrash(_ url: URL, fixture: Fixture) throws -> URL? {
        let destination = fixture.fakeTrash.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func testMovesOnlySelectedPhoneAndIndexToInjectedTrash() throws {
        let f = try fixture()
        let other = f.directory.deletingLastPathComponent().appendingPathComponent("Other.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("other guest".utf8).write(to: other.appendingPathComponent("userdata-qemu.img"))
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        XCTAssertEqual(plan.avd.indexURL, f.index)
        XCTAssertEqual(plan.directoryURL, f.directory)
        var moved: [String] = []
        try AVDDeletionStore.delete(plan) { url in
            moved.append(url.lastPathComponent)
            return try moveToTestTrash(url, fixture: f)
        }
        XCTAssertEqual(moved, ["Phone.ini", "Phone.avd"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.index.path))
        XCTAssertEqual(try String(contentsOf: f.fakeTrash.appendingPathComponent("Phone.avd/userdata-qemu.img")), "guest apps and files")
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("userdata-qemu.img")), "other guest")
        XCTAssertEqual(try String(contentsOf: f.sdk.root.appendingPathComponent("keep.txt")), "shared SDK content")
    }

    func testRejectsMissingOrMismatchedIndex() throws {
        let f = try fixture()
        let noIndex = AVD(name: "Phone", configURL: f.config)
        XCTAssertThrowsError(try AVDDeletionStore.prepare(avd: noIndex, sdk: f.sdk))
        try Data("path=/tmp/Other.avd\n".utf8).write(to: f.index)
        XCTAssertThrowsError(try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk))
        try Data("path=\(f.directory.path)\npath.rel=avd/Other.avd\n".utf8).write(to: f.index)
        XCTAssertThrowsError(try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.path))
    }

    func testRejectsBroadDirectoryAndSDKContents() throws {
        let f = try fixture()
        let broad = AVD(name: "Phone", configURL: f.root.appendingPathComponent("config.ini"), indexURL: f.index)
        XCTAssertThrowsError(try AVDDeletionStore.prepare(avd: broad, sdk: f.sdk))
        let overlappingSDK = SDKInstallation(root: f.directory, emulator: f.directory.appendingPathComponent("emulator"), adb: f.directory.appendingPathComponent("adb"))
        XCTAssertThrowsError(try AVDDeletionStore.prepare(avd: f.avd, sdk: overlappingSDK))
    }

    func testRejectsSymlinkedConfigIndexAndDirectory() throws {
        for kind in ["config", "index", "directory"] {
            let f = try fixture()
            let target = kind == "config" ? f.config : kind == "index" ? f.index : f.directory
            let original = f.root.appendingPathComponent("original-" + target.lastPathComponent)
            try FileManager.default.moveItem(at: target, to: original)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
            XCTAssertThrowsError(try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk), kind)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        }
    }

    func testRejectsChangedConfigurationAndIndexBeforeAnyMove() throws {
        for kind in ["config", "index"] {
            let f = try fixture()
            let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
            let target = kind == "config" ? f.config : f.index
            var bytes = try Data(contentsOf: target)
            bytes.append(Data("# another tool changed this file\n".utf8))
            try bytes.write(to: target)
            var invoked = false
            XCTAssertThrowsError(try AVDDeletionStore.delete(plan) { _ in invoked = true; return nil })
            XCTAssertFalse(invoked)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
        }
    }

    func testRejectsReplacedDirectoryEvenWithIdenticalConfiguration() throws {
        let f = try fixture()
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        let original = f.root.appendingPathComponent("preserved-original.avd")
        try FileManager.default.moveItem(at: f.directory, to: original)
        try FileManager.default.copyItem(at: original, to: f.directory)
        var invoked = false
        XCTAssertThrowsError(try AVDDeletionStore.delete(plan) { _ in invoked = true; return nil })
        XCTAssertFalse(invoked)
    }

    func testRejectsRunningLockCreatedAfterConfirmation() throws {
        let f = try fixture()
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: f.directory.appendingPathComponent("hardware-qemu.ini.lock"))
        var invoked = false
        XCTAssertThrowsError(try AVDDeletionStore.delete(plan) { _ in invoked = true; return nil })
        XCTAssertFalse(invoked)
    }

    func testStalePIDMarkerAllowsTrashAndRemainsWithThePreservedPhoneData() throws {
        let f = try fixture()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        let pid = child.processIdentifier
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let lock = f.directory.appendingPathComponent("hardware-qemu.ini.lock")
        let marker = Data("\(pid)\0".utf8)
        try marker.write(to: lock)
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        XCTAssertEqual(try Data(contentsOf: lock), marker, "Inspection must not remove stale markers")

        try AVDDeletionStore.delete(plan) { try moveToTestTrash($0, fixture: f) }

        XCTAssertEqual(try Data(contentsOf: f.fakeTrash.appendingPathComponent("Phone.avd/hardware-qemu.ini.lock")), marker)
        XCTAssertEqual(try String(contentsOf: f.fakeTrash.appendingPathComponent("Phone.avd/userdata-qemu.img")), "guest apps and files")
        XCTAssertEqual(try String(contentsOf: f.sdk.root.appendingPathComponent("keep.txt")), "shared SDK content")
    }

    func testStaleMarkerThatAcquiresALiveOwnerAfterConfirmationBlocksEveryMove() throws {
        let f = try fixture()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(kill(child.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let lock = f.directory.appendingPathComponent("hardware-qemu.ini.lock")
        try Data("\(child.processIdentifier)\0".utf8).write(to: lock)
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        let liveMarker = Data("\(ProcessInfo.processInfo.processIdentifier)\0".utf8)
        try liveMarker.write(to: lock)
        var moved = false

        XCTAssertThrowsError(try AVDDeletionStore.delete(plan) { _ in moved = true; return nil }) {
            XCTAssertEqual($0 as? AVDDeletionError, .deviceInUse)
        }
        XCTAssertFalse(moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.index.path))
        XCTAssertEqual(try Data(contentsOf: lock), liveMarker)
    }

    func testRejectsAnotherIndexReferencingSameDataFolder() throws {
        let f = try fixture()
        let alias = f.index.deletingLastPathComponent().appendingPathComponent("Alias.ini")
        try Data("path=\(f.directory.path)\n".utf8).write(to: alias)
        XCTAssertThrowsError(try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)) { error in
            XCTAssertEqual(error as? AVDDeletionError, .sharedDirectory)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.path))
    }

    func testRejectsAliasCreatedAfterConfirmation() throws {
        let f = try fixture()
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        let alias = f.index.deletingLastPathComponent().appendingPathComponent("Alias.ini")
        try Data("path.rel=avd/Phone.avd\n".utf8).write(to: alias)
        var invoked = false
        XCTAssertThrowsError(try AVDDeletionStore.delete(plan) { _ in invoked = true; return nil })
        XCTAssertFalse(invoked)
    }

    func testFailureOnFirstMovePreservesOriginalFiles() throws {
        let f = try fixture()
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        XCTAssertThrowsError(try AVDDeletionStore.delete(plan) { _ in throw CocoaError(.fileWriteNoPermission) }) { error in
            guard case AVDDeletionError.trashFailed = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.index.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.config.path))
    }

    func testFailureOnFolderMoveRestoresIndex() throws {
        let f = try fixture()
        let indexBytes = try Data(contentsOf: f.index)
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        XCTAssertThrowsError(try AVDDeletionStore.delete(plan) { url in
            if url == f.directory { throw CocoaError(.fileWriteNoPermission) }
            return try moveToTestTrash(url, fixture: f)
        }) { error in
            guard case AVDDeletionError.trashFailed = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: f.index), indexBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.config.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.fakeTrash.path).isEmpty)
    }

    func testRollbackNeverOverwritesNewIndexAndReportsPartialFailure() throws {
        let f = try fixture()
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        XCTAssertThrowsError(try AVDDeletionStore.delete(plan) { url in
            if url == f.directory {
                try Data("a new index".utf8).write(to: f.index)
                throw CocoaError(.fileWriteNoPermission)
            }
            return try moveToTestTrash(url, fixture: f)
        }) { error in
            guard case AVDDeletionError.partialTrashFailure = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: f.index), "a new index")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.fakeTrash.appendingPathComponent("Phone.ini").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.config.path))
    }

    func testConfigurationChangedDuringMoveRestoresIndexAndPreservesChange() throws {
        let f = try fixture()
        let plan = try AVDDeletionStore.prepare(avd: f.avd, sdk: f.sdk)
        var moves = 0
        XCTAssertThrowsError(try AVDDeletionStore.delete(plan) { url in
            moves += 1
            let result = try moveToTestTrash(url, fixture: f)
            try Data("changed configuration".utf8).write(to: f.config)
            return result
        })
        XCTAssertEqual(moves, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.index.path))
        XCTAssertEqual(try String(contentsOf: f.config), "changed configuration")
    }
}

import XCTest
@testable import SimulatorKit

final class DiagnosticsBundleTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Diagnostics Bundle Tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testZIPContainsOnlyFixedMembersAndExactSuppliedContent() async throws {
        let root = try directory()
        let runtime = root.appendingPathComponent("runtime ;$(touch pwn).log")
        let journal = root.appendingPathComponent("session events.jsonl")
        try Data("emulator output\n".utf8).write(to: runtime)
        try Data("{\"state\":\"running\"}\n".utf8).write(to: journal)
        try Data("unrelated private content".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
        let destination = root.appendingPathComponent("Session diagnostics with spaces.zip")
        try Data("older export".utf8).write(to: destination)
        try await DiagnosticsBundle.export(destinationURL: destination, diagnosticsString: "Device: Test\nFrame: 1080×1920\n",
                                           runtimeLogURL: runtime, journalURL: journal, logLinesString: "Logcat 日本語🙂\n")
        let archiveMembers = try await members(destination)
        XCTAssertEqual(archiveMembers, Set(["manifest.json", "diagnostics.txt", "emulator.log", "session-events.jsonl", "logcat.txt"]))
        let diagnostics = try await content(destination, "diagnostics.txt")
        let emulator = try await content(destination, "emulator.log")
        let events = try await content(destination, "session-events.jsonl")
        let logs = try await content(destination, "logcat.txt")
        XCTAssertEqual(String(decoding: diagnostics, as: UTF8.self), "Device: Test\nFrame: 1080×1920\n")
        XCTAssertEqual(String(decoding: emulator, as: UTF8.self), "emulator output\n")
        XCTAssertEqual(String(decoding: events, as: UTF8.self), "{\"state\":\"running\"}\n")
        XCTAssertEqual(String(decoding: logs, as: UTF8.self), "Logcat 日本語🙂\n")
        let manifest = try await manifest(destination)
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertTrue(entries.allSatisfy { $0["status"] as? String == "included" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pwn").path))
        let verification = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-t", destination.path])
        XCTAssertEqual(verification.status, 0)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".AndroidSimulatorDiagnostics-") })
    }

    func testMissingAndSymlinkLogsAreExplicitlyOmittedWithoutReadingOtherFiles() async throws {
        let root = try directory()
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("not part of the supplied session".utf8).write(to: unrelated)
        let symlink = root.appendingPathComponent("journal-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)
        let destination = root.appendingPathComponent("omissions.zip")
        try await DiagnosticsBundle.export(destinationURL: destination, diagnosticsString: "diagnostics",
                                           runtimeLogURL: root.appendingPathComponent("missing.log"), journalURL: symlink)
        let archiveMembers = try await members(destination)
        XCTAssertEqual(archiveMembers, Set(["manifest.json", "diagnostics.txt"]))
        let value = try await manifest(destination)
        let entries = try XCTUnwrap(value["entries"] as? [[String: Any]])
        let runtime = try XCTUnwrap(entries.first { $0["name"] as? String == "emulator.log" })
        let journal = try XCTUnwrap(entries.first { $0["name"] as? String == "session-events.jsonl" })
        XCTAssertEqual(runtime["status"] as? String, "omitted")
        XCTAssertTrue((runtime["note"] as? String)?.contains("no longer available") == true)
        XCTAssertEqual(journal["status"] as? String, "omitted")
        XCTAssertTrue((journal["note"] as? String)?.contains("Symbolic links") == true)
    }

    func testLargeInputsHaveBoundedTailsAndArchiveSize() async throws {
        let root = try directory()
        let runtime = root.appendingPathComponent("large.log")
        let line = String(repeating: "x", count: 1000) + "\n"
        let source = String(repeating: line, count: 3000) + "FINAL MARKER\n"
        try Data(source.utf8).write(to: runtime)
        let destination = root.appendingPathComponent("bounded.zip")
        try await DiagnosticsBundle.export(destinationURL: destination,
                                           diagnosticsString: String(repeating: "🙂", count: 100_000),
                                           runtimeLogURL: runtime, journalURL: runtime, logLinesString: source)
        for name in ["emulator.log", "session-events.jsonl", "logcat.txt"] {
            let bytes = try await content(destination, name)
            XCTAssertLessThanOrEqual(bytes.count, DiagnosticsBundle.maximumLogBytes)
            XCTAssertTrue(String(decoding: bytes, as: UTF8.self).hasSuffix("FINAL MARKER\n"))
            XCTAssertTrue(String(decoding: bytes, as: UTF8.self).hasPrefix(line), "Truncated multiline logs must begin at a complete line")
        }
        let diagnostics = try await content(destination, "diagnostics.txt")
        XCTAssertLessThanOrEqual(diagnostics.count, DiagnosticsBundle.maximumDiagnosticsBytes)
        XCTAssertNotNil(String(data: diagnostics, encoding: .utf8))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)
        XCTAssertLessThanOrEqual(size.intValue, DiagnosticsBundle.maximumArchiveBytes)
        let value = try await manifest(destination)
        let entries = try XCTUnwrap(value["entries"] as? [[String: Any]])
        XCTAssertTrue(entries.allSatisfy { $0["truncated"] as? Bool == true })
    }

    func testUnreadableFilesAndDirectoriesAreAnnotatedWithoutTraversal() async throws {
        let root = try directory()
        let unreadable = root.appendingPathComponent("unreadable.log")
        try Data("restricted log".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let destination = root.appendingPathComponent("unreadable.zip")
        try await DiagnosticsBundle.export(destinationURL: destination, diagnosticsString: "diagnostics",
                                           runtimeLogURL: unreadable, journalURL: root)
        let archiveMembers = try await members(destination)
        XCTAssertEqual(archiveMembers, Set(["manifest.json", "diagnostics.txt"]))
        let value = try await manifest(destination)
        let entries = try XCTUnwrap(value["entries"] as? [[String: Any]])
        let runtime = try XCTUnwrap(entries.first { $0["name"] as? String == "emulator.log" })
        let journal = try XCTUnwrap(entries.first { $0["name"] as? String == "session-events.jsonl" })
        XCTAssertEqual(runtime["status"] as? String, "omitted")
        XCTAssertTrue((runtime["note"] as? String)?.contains("not readable") == true)
        XCTAssertEqual(journal["status"] as? String, "omitted")
        XCTAssertTrue((journal["note"] as? String)?.contains("directories and special files are excluded") == true)
    }

    func testDestinationFailureAndCancellationPreserveExistingExport() async throws {
        let root = try directory()
        let destination = root.appendingPathComponent("existing.zip")
        let original = Data("earlier export".utf8)
        try original.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        do {
            try await DiagnosticsBundle.export(destinationURL: destination, diagnosticsString: "new diagnostics")
            XCTFail("An unwritable destination directory must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Diagnostics could not be exported"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DiagnosticsBundle.export(destinationURL: destination, diagnosticsString: "cancelled diagnostics")
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.zip"])
    }

    private func members(_ url: URL) async throws -> Set<String> {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z", "-1", url.path])
        try result.requireSuccess(operation: "List test diagnostics ZIP")
        return Set(result.text.split(whereSeparator: \.isNewline).map(String.init))
    }

    private func content(_ url: URL, _ name: String) async throws -> Data {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", url.path, name])
        try result.requireSuccess(operation: "Read test diagnostics ZIP")
        return result.stdout
    }

    private func manifest(_ url: URL) async throws -> [String: Any] {
        let data = try await content(url, "manifest.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

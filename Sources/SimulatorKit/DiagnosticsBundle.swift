import Foundation
import Darwin

/// Creates an export from explicit session inputs only. Archive names are fixed;
/// neither supplied filenames nor directory contents become archive members.
public enum DiagnosticsBundle {
    public static let maximumDiagnosticsBytes = 256 * 1_024
    public static let maximumLogBytes = 1_024 * 1_024
    public static let maximumArchiveBytes = 4 * 1_024 * 1_024

    /// Optional unavailable, unreadable, or non-regular log files are recorded
    /// as omissions in manifest.json. File work runs on a utility task. The
    /// existing destination is replaced atomically only after ZIP creation.
    @discardableResult
    public static func export(destinationURL: URL, diagnosticsString: String,
                              runtimeLogURL: URL? = nil, journalURL: URL? = nil,
                              logLinesString: String? = nil) async throws -> URL {
        let work = Task.detached(priority: .utility) {
            do {
                return try await create(destinationURL: destinationURL, diagnosticsString: diagnosticsString,
                                        runtimeLogURL: runtimeLogURL, journalURL: journalURL,
                                        logLinesString: logLinesString)
            } catch is CancellationError { throw CancellationError() }
            catch let error as DiagnosticsBundleError { throw error }
            catch { throw DiagnosticsBundleError.exportFailed(error.localizedDescription) }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    private struct Entry: Encodable {
        let name: String
        let status: String
        let sourceFileName: String?
        let sourceBytes: UInt64?
        let capturedBytes: Int
        let truncated: Bool
        let note: String?
    }
    private struct Manifest: Encodable {
        let schemaVersion = 1
        let createdAt: Date
        let application = "DroidDock"
        let maximumArchiveBytes = DiagnosticsBundle.maximumArchiveBytes
        let entries: [Entry]
    }
    private enum Capture {
        case included(Data, sourceBytes: UInt64)
        case omitted(String)
    }

    private static func create(destinationURL: URL, diagnosticsString: String,
                               runtimeLogURL: URL?, journalURL: URL?, logLinesString: String?) async throws -> URL {
        try Task.checkCancellation()
        guard destinationURL.isFileURL, !destinationURL.hasDirectoryPath,
              !destinationURL.path.contains("\0"), !destinationURL.lastPathComponent.isEmpty else {
            throw DiagnosticsBundleError.invalidDestination
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw DiagnosticsBundleError.invalidDestination
        }
        let staging = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".AndroidSimulatorDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try manager.createDirectory(at: payload, withIntermediateDirectories: false)
        var entries: [Entry] = []

        let diagnosticsBytes = diagnosticsString.utf8.count
        let diagnostics = validUTF8Prefix(diagnosticsString, limit: maximumDiagnosticsBytes)
        try diagnostics.write(to: payload.appendingPathComponent("diagnostics.txt"))
        entries.append(Entry(name: "diagnostics.txt", status: "included", sourceFileName: nil,
                             sourceBytes: UInt64(diagnosticsBytes), capturedBytes: diagnostics.count,
                             truncated: diagnostics.count < diagnosticsBytes, note: "Session diagnostics supplied by the application."))

        for (name, url) in [("emulator.log", runtimeLogURL), ("session-events.jsonl", journalURL)] {
            try Task.checkCancellation()
            guard let url else {
                entries.append(Entry(name: name, status: "notProvided", sourceFileName: nil, sourceBytes: nil,
                                     capturedBytes: 0, truncated: false, note: "No source log was supplied."))
                continue
            }
            let sourceName = String(decoding: validUTF8Prefix(url.lastPathComponent, limit: 256), as: UTF8.self)
            switch captureTail(url) {
            case let .included(data, sourceBytes):
                try data.write(to: payload.appendingPathComponent(name))
                entries.append(Entry(name: name, status: "included", sourceFileName: sourceName,
                                     sourceBytes: sourceBytes, capturedBytes: data.count,
                                     truncated: UInt64(data.count) < sourceBytes,
                                     note: "Captured from the supplied file only. Large logs retain a bounded tail; partial leading lines are removed when possible."))
            case let .omitted(reason):
                entries.append(Entry(name: name, status: "omitted", sourceFileName: sourceName, sourceBytes: nil,
                                     capturedBytes: 0, truncated: false, note: reason))
            }
        }
        if let logLinesString {
            let sourceBytes = logLinesString.utf8.count
            let lines = completeTail(Data(logLinesString.utf8.suffix(maximumLogBytes)), wasTruncated: sourceBytes > maximumLogBytes)
            try lines.write(to: payload.appendingPathComponent("logcat.txt"))
            entries.append(Entry(name: "logcat.txt", status: "included", sourceFileName: nil,
                                 sourceBytes: UInt64(sourceBytes), capturedBytes: lines.count,
                                 truncated: lines.count < sourceBytes, note: "Logcat lines supplied by the application."))
        } else {
            entries.append(Entry(name: "logcat.txt", status: "notProvided", sourceFileName: nil, sourceBytes: nil,
                                 capturedBytes: 0, truncated: false, note: "No Logcat text was supplied."))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Manifest(createdAt: Date(), entries: entries)).write(to: payload.appendingPathComponent("manifest.json"))
        try Task.checkCancellation()
        let archive = staging.appendingPathComponent("bundle.zip")
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--noqtn", payload.path, archive.path], timeout: 30)
        try result.requireSuccess(operation: "Create diagnostics ZIP")
        let size = (try manager.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0, size <= UInt64(maximumArchiveBytes) else { throw DiagnosticsBundleError.archiveTooLarge }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        try Task.checkCancellation()
        // Staging is on the destination volume. POSIX rename replaces a file
        // atomically, so no failed copy or compression can erase an older export.
        guard Darwin.rename(archive.path, destinationURL.path) == 0 else {
            throw DiagnosticsBundleError.exportFailed("The ZIP could not be saved at the selected destination: \(String(cString: strerror(errno))).")
        }
        return destinationURL
    }

    private static func captureTail(_ url: URL) -> Capture {
        guard url.isFileURL, !url.path.contains("\0") else { return .omitted("The source was not a valid local file URL.") }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return .omitted("The requested log file was no longer available.")
            case EACCES, EPERM: return .omitted("The requested log file was not readable.")
            case ELOOP: return .omitted("Symbolic links are excluded from diagnostic exports.")
            default: return .omitted("The requested log could not be opened: \(String(cString: strerror(errno))).")
            }
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .omitted("The requested log metadata could not be read.") }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else {
            return .omitted("Only regular log files are included; directories and special files are excluded.")
        }
        let size = UInt64(info.st_size)
        var offset = max(0, info.st_size - off_t(maximumLogBytes))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count < maximumLogBytes, offset < info.st_size {
            let requested = min(buffer.count, maximumLogBytes - data.count, Int(info.st_size - offset))
            let count = pread(descriptor, &buffer, requested, offset)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .omitted("The requested log could not be read: \(String(cString: strerror(errno))).")
            }
            data.append(contentsOf: buffer.prefix(count))
            offset += off_t(count)
        }
        return .included(completeTail(data, wasTruncated: size > UInt64(maximumLogBytes)), sourceBytes: size)
    }

    private static func completeTail(_ bytes: Data, wasTruncated: Bool) -> Data {
        guard wasTruncated else { return bytes }
        var tail = bytes
        if let newline = tail.firstIndex(of: 10), newline != tail.index(before: tail.endIndex) {
            tail.removeSubrange(...newline)
        } else {
            // A single very long line still has a useful bounded suffix. Avoid
            // beginning its UTF-8 text in the middle of a scalar when possible.
            while let first = tail.first, first & 0xC0 == 0x80 { tail.removeFirst() }
        }
        return tail
    }

    private static func validUTF8Prefix(_ text: String, limit: Int) -> Data {
        var data = Data(text.utf8.prefix(limit))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return data
    }
}

public enum DiagnosticsBundleError: LocalizedError, Sendable {
    case invalidDestination
    case archiveTooLarge
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: return "Choose a local file destination for the diagnostics ZIP, rather than a folder."
        case .archiveTooLarge: return "The diagnostics ZIP exceeded its 4 MB limit. Export fewer Logcat lines and try again."
        case let .exportFailed(reason): return "Diagnostics could not be exported. \(reason)"
        }
    }
}

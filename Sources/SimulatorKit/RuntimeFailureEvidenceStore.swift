import Foundation
import Darwin

/// Automatic, local evidence for an app-owned runtime that exited unexpectedly.
/// Only eight fixed archive names inside this dedicated directory are managed;
/// no directory crawling or user-selected export destination is involved.
public actor RuntimeFailureEvidenceStore {
    public static let maximumArchives = 8
    public static let maximumInlineLogBytes = 4 * 1_024
    public static let shared = RuntimeFailureEvidenceStore()
    public nonisolated let directoryURL: URL
    private var reservedSlots: Set<Int> = []

    public struct Exit: Sendable, Equatable {
        public let runtimeID: UUID
        public let sessionID: UUID
        public let processID: Int32
        public let serial: String
        public let avdName: String
        public let consolePort: Int
        public let status: Int32
        public let reason: String
        public let observedAt: Date

        public init(runtimeID: UUID, sessionID: UUID, processID: Int32, serial: String,
                    avdName: String, consolePort: Int, status: Int32, reason: String,
                    observedAt: Date = Date()) {
            self.runtimeID = runtimeID; self.sessionID = sessionID; self.processID = processID
            self.serial = serial; self.avdName = avdName; self.consolePort = consolePort
            self.status = status; self.reason = reason; self.observedAt = observedAt
        }

        public var message: String {
            "The emulator process exited (\(reason), status \(status)). You can start this device again."
        }
        public var diagnostics: String {
            "Last unexpected runtime exit\nObserved: \(observedAt)\nExit runtime ID: \(runtimeID.uuidString)\nExit session ID: \(sessionID.uuidString)\nExit owned PID: \(processID)\nExit ADB serial: \(serial)\nExit AVD: \(avdName)\nExit console port: \(consolePort)\nExit reason: \(reason)\nExit status: \(status)\n"
        }
    }

    public struct Record: Sendable {
        public let exit: Exit
        public let recentOutput: String
        public let archiveURL: URL?
        public let warning: String?
        public let complete: Bool

        public init(exit: Exit, recentOutput: String = "", archiveURL: URL? = nil,
                    warning: String? = nil, complete: Bool = false) {
            self.exit = exit; self.recentOutput = recentOutput; self.archiveURL = archiveURL
            self.warning = warning; self.complete = complete
        }
        public var message: String {
            var value = exit.message
            if !recentOutput.isEmpty { value += "\n\nRecent runtime output (stdout/stderr):\n" + recentOutput }
            if let archiveURL { value += "\n\nDiagnostics saved: " + archiveURL.path }
            if let warning { value += "\n\nFailure evidence: " + warning }
            return value
        }
        public var diagnostics: String {
            exit.diagnostics + "Automatic failure bundle: \(archiveURL?.path ?? (complete ? "Unavailable" : "Saving…"))\nAutomatic retention: eight reusable archive slots; older bundles may be replaced by later failures.\nFailure evidence warning: \(warning ?? "None")\nRecent runtime output (bounded stdout/stderr tail):\n\(recentOutput.isEmpty ? "No output captured." : recentOutput)\n"
        }
    }

    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AndroidSimulator/Failures", isDirectory: true)
    }

    /// Call from cancellation-independent cleanup when evidence must survive a
    /// simultaneous Stop/Quit request. File work runs on this actor/utility work,
    /// while the existing bundle exporter performs compression asynchronously.
    public func preserve(exit: Exit, diagnosticsString: String, runtimeLogURL: URL,
                         journalURL: URL?, logLinesString: String?, runtimeLogWarning: String? = nil) async -> Record {
        let tail = Self.readTail(runtimeLogURL)
        let warnings = [runtimeLogWarning, tail.warning].compactMap { $0 }
        let captureWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        do {
            let slot = try reserveSlot()
            defer { reservedSlots.remove(slot) }
            let destination = directoryURL.appendingPathComponent("runtime-exit-\(slot).zip")
            let expected = Record(exit: exit, recentOutput: tail.text, archiveURL: destination,
                                  warning: captureWarning, complete: true)
            try await DiagnosticsBundle.export(destinationURL: destination,
                diagnosticsString: diagnosticsString + "\n" + expected.diagnostics,
                runtimeLogURL: runtimeLogURL, journalURL: journalURL, logLinesString: logLinesString)
            return expected
        } catch {
            let warning = [captureWarning, "The automatic bundle could not be saved: \(error.localizedDescription)"]
                .compactMap { $0 }.joined(separator: " ")
            return Record(exit: exit, recentOutput: tail.text, warning: warning, complete: true)
        }
    }

    private func reserveSlot() throws -> Int {
        guard directoryURL.isFileURL, !directoryURL.path.contains("\0") else {
            throw RuntimeError.invalidArgument("Automatic failure evidence requires a local directory.")
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(directoryURL.path, &directoryInfo) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), directoryInfo.st_uid == geteuid() else {
            throw RuntimeError.invalidArgument("The automatic failure directory must be an owned real directory, not a symbolic link.")
        }
        var oldest: (slot: Int, seconds: Int, nanos: Int)?
        for slot in 0..<Self.maximumArchives where !reservedSlots.contains(slot) {
            let url = directoryURL.appendingPathComponent("runtime-exit-\(slot).zip")
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { reservedSlots.insert(slot); return slot }
                continue
            }
            // Do not replace a directory, link or file owned by another user.
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid() else { continue }
            let candidate = (slot, Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec))
            if oldest == nil || candidate.1 < oldest!.seconds ||
                (candidate.1 == oldest!.seconds && candidate.2 < oldest!.nanos) {
                oldest = candidate
            }
        }
        guard let slot = oldest?.slot else {
            throw RuntimeError.invalidArgument("Automatic failure archive slots are busy or unavailable. The runtime log is still available for manual export.")
        }
        reservedSlots.insert(slot)
        return slot
    }

    private static func readTail(_ url: URL) -> (text: String, warning: String?) {
        guard url.isFileURL, !url.path.contains("\0") else { return ("", "The runtime log URL was invalid.") }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return ("", "The runtime log tail was unavailable: \(String(cString: strerror(errno))).") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else {
            return ("", "The runtime log was not a readable regular file.")
        }
        let count = Int(min(info.st_size, off_t(maximumInlineLogBytes)))
        guard count > 0 else { return ("", nil) }
        var bytes = [UInt8](repeating: 0, count: count)
        let received = pread(descriptor, &bytes, count, info.st_size - off_t(count))
        guard received >= 0 else { return ("", "The runtime log tail could not be read: \(String(cString: strerror(errno))).") }
        let suffix = bytes.prefix(received).drop(while: { $0 & 0xC0 == 0x80 })
        let text = String(decoding: suffix, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(20).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Invalid source bytes can expand during decoding. Bound the resulting
        // text too, without splitting a Unicode scalar.
        let bounded = text.utf8.suffix(maximumInlineLogBytes).drop(while: { $0 & 0xC0 == 0x80 })
        return (String(decoding: bounded, as: UTF8.self), nil)
    }
}

import Foundation
import Darwin

/// Persistent hints about children launched by this app. A match is diagnostic
/// evidence only: this actor has no adoption, ownership, or process signal API.
/// Share one instance for a ledger file; all file operations are actor serialized.
public actor RuntimeLedger {
    public enum Disposition: String, Codable, Sendable {
        case running, intentionallyLeftRunning
    }

    public struct Match: Identifiable, Sendable, Equatable {
        public var id: UUID { runtimeID }
        public let runtimeID: UUID
        public let pid: Int32
        public let serial: String
        public let avdName: String
        public let disposition: Disposition
        public let recordedAt: Date
        public let executablePath: String
    }

    public enum Error: LocalizedError, Sendable {
        case invalidLocation
        case unavailableProcess(Int32)
        case invalidRuntime
        case corruptLedger(String)
        case inaccessibleLedger(String, String)
        case writeFailed(String, String)
        case ledgerIsNotCorrupt

        public var errorDescription: String? {
            switch self {
            case .invalidLocation: return "Runtime history requires a local file URL."
            case .unavailableProcess(let pid): return "The identity of emulator process \(pid) could not be read. It was not added to runtime history."
            case .invalidRuntime: return "This emulator has incomplete runtime identity information and could not be added to runtime history."
            case .corruptLedger(let path): return "Runtime history at \(path) is damaged or exceeds its size limit. Reset this history to rebuild it; existing emulators remain external."
            case let .inaccessibleLedger(path, detail): return "Runtime history at \(path) could not be read: \(detail). Check the file's permissions and try again."
            case let .writeFailed(path, detail): return "Runtime history at \(path) could not be saved: \(detail). Check the folder's permissions and available space."
            case .ledgerIsNotCorrupt: return "Runtime history is not damaged, so it was not reset."
            }
        }
    }

    public nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AndroidSimulator", isDirectory: true)
            .appendingPathComponent("runtime-ledger.json")
    }
    public nonisolated static let maximumEntries = 64
    public nonisolated static let maximumFileBytes = 256 * 1_024
    public nonisolated let url: URL

    struct ProcessIdentity: Codable, Sendable, Equatable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let executablePath: String
    }

    struct Entry: Codable, Sendable {
        let runtimeID: UUID
        let process: ProcessIdentity
        let serial: String
        let avdName: String
        let sdkRoot: String
        let sdkEmulator: String
        let sdkADB: String
        var disposition: Disposition
        let recordedAt: Date
    }

    struct Document: Codable {
        let version: Int
        var entries: [Entry]
    }

    private let identify: @Sendable (Int32) -> ProcessIdentity?

    public init(url: URL = RuntimeLedger.defaultURL) {
        self.url = url
        identify = { Self.nativeIdentity($0) }
    }

    // Fixture seam for PID reuse and exec tests; not a public process identity API.
    init(url: URL, identify: @escaping @Sendable (Int32) -> ProcessIdentity?) {
        self.url = url
        self.identify = identify
    }

    /// Record after launch, then again once Android is ready: an emulator may
    /// exec its QEMU binary during boot while retaining the launch PID.
    public func record(runtime: RunningEmulator, sdk: SDKInstallation) throws {
        let pid = runtime.process.processIdentifier
        guard runtime.process.isRunning, let process = identify(pid),
              runtime.process.isRunning else { throw Error.unavailableProcess(pid) }
        let entry = Entry(runtimeID: runtime.id, process: process, serial: runtime.serial,
            avdName: runtime.avdName, sdkRoot: Self.path(sdk.root),
            sdkEmulator: Self.path(sdk.emulator), sdkADB: Self.path(sdk.adb),
            disposition: .running, recordedAt: Date())
        guard Self.valid(entry), runtime.serial == "emulator-\(runtime.consolePort)",
              runtime.process.executableURL.map(Self.path) == entry.sdkEmulator else { throw Error.invalidRuntime }
        var entries = try read().entries
        entries.removeAll { $0.runtimeID == entry.runtimeID || $0.process == process }
        entries.append(entry)
        try write(entries)
    }

    public func markLeftRunning(id: UUID) throws {
        var entries = try read().entries
        guard let index = entries.firstIndex(where: { $0.runtimeID == id }) else { return }
        entries[index].disposition = .intentionallyLeftRunning
        try write(entries)
    }

    public func remove(id: UUID) throws {
        var entries = try read().entries
        let count = entries.count
        entries.removeAll { $0.runtimeID == id }
        if entries.count != count { try write(entries) }
    }

    /// This inspection performs no writes and never grants control of a match.
    /// Offline devices or unavailable native identities cannot establish a match.
    public func inspect(discovered: [ADBDevice], sdk: SDKInstallation,
                        excludingRuntimeIDs: Set<UUID> = []) throws -> [Match] {
        let entries = try read().entries
        let root = Self.path(sdk.root), emulator = Self.path(sdk.emulator), adb = Self.path(sdk.adb)
        return entries.compactMap { entry in
            guard !excludingRuntimeIDs.contains(entry.runtimeID),
                  entry.sdkRoot == root, entry.sdkEmulator == emulator, entry.sdkADB == adb,
                  discovered.contains(where: { $0.state == "device" && $0.serial == entry.serial && $0.avdName == entry.avdName }),
                  identify(entry.process.pid) == entry.process else { return nil }
            return Match(runtimeID: entry.runtimeID, pid: entry.process.pid, serial: entry.serial,
                avdName: entry.avdName, disposition: entry.disposition,
                recordedAt: entry.recordedAt, executablePath: entry.process.executablePath)
        }.sorted { $0.serial < $1.serial }
    }

    /// Explicit recovery of damaged metadata only. A valid, missing, inaccessible,
    /// or symlinked ledger is never discarded by this method.
    public func resetCorruptLedger() throws {
        do { _ = try read() }
        catch Error.corruptLedger { try write([]); return }
        throw Error.ledgerIsNotCorrupt
    }

    private func read() throws -> Document {
        try validateLocation()
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return Document(version: 1, entries: []) }
            throw Error.inaccessibleLedger(url.path, String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw Error.inaccessibleLedger(url.path, String(cString: strerror(errno)))
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw Error.inaccessibleLedger(url.path, "The history path is not a regular file")
        }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumFileBytes else { throw Error.corruptLedger(url.path) }
        let data: Data
        do { data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data() }
        catch { throw Error.inaccessibleLedger(url.path, error.localizedDescription) }
        guard data.count <= Self.maximumFileBytes,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1, document.entries.count <= Self.maximumEntries,
              Set(document.entries.map(\.runtimeID)).count == document.entries.count,
              document.entries.allSatisfy(Self.valid) else { throw Error.corruptLedger(url.path) }
        return document
    }

    private func write(_ original: [Entry]) throws {
        try validateLocation()
        var entries = original.sorted { $0.recordedAt < $1.recordedAt }
        if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Document(version: 1, entries: entries))
        while data.count > Self.maximumFileBytes, !entries.isEmpty {
            entries.removeFirst()
            data = try encoder.encode(Document(version: 1, entries: entries))
        }
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".runtime-ledger-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            // Do not replace a symlink or special file if the path changed since
            // the preceding read. rename itself never follows the leaf symlink.
            var existing = stat()
            if lstat(url.path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG else {
                    throw Error.writeFailed(url.path, "The history path is not a regular file")
                }
            } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch let error as Error { throw error }
        catch { throw Error.writeFailed(url.path, error.localizedDescription) }
    }

    private func validateLocation() throws {
        guard url.isFileURL, !url.hasDirectoryPath, !url.lastPathComponent.isEmpty else { throw Error.invalidLocation }
    }

    private static func valid(_ entry: Entry) -> Bool {
        let identity = entry.process
        guard identity.pid > 0, identity.startSeconds > 0, identity.startMicroseconds < 1_000_000,
              entry.recordedAt.timeIntervalSinceReferenceDate.isFinite,
              AVDRepository.isValidName(entry.avdName), entry.avdName.utf8.count <= 256,
              entry.serial.hasPrefix("emulator-"), entry.serial.utf8.count <= 32,
              let port = Int(entry.serial.dropFirst("emulator-".count)), (1...65534).contains(port), port % 2 == 0 else { return false }
        return [identity.executablePath, entry.sdkRoot, entry.sdkEmulator, entry.sdkADB].allSatisfy {
            $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4_096
        }
    }

    private static func path(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func nativeIdentity(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        func readBSDInfo() -> proc_bsdinfo? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pid == UInt32(pid) else { return nil }
            return info
        }
        guard let before = readBSDInfo() else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is the non-importable C macro 4 * MAXPATHLEN.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0, Int(length) < buffer.count, let after = readBSDInfo(),
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: after.pbi_start_tvsec,
            startMicroseconds: after.pbi_start_tvusec,
            executablePath: path(URL(fileURLWithPath: String(cString: buffer))))
    }
}

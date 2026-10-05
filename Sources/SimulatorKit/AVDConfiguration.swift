import Darwin
import Foundation

public struct AVDConfiguration: Equatable, Sendable {
    public var displayName: String
    public var memoryMB: Int
    public var cpuCores: Int
    public var width: Int
    public var height: Int
    public var density: Int

    public init(displayName: String, memoryMB: Int = 2048, cpuCores: Int = 4,
                width: Int = 1080, height: Int = 2400, density: Int = 420) {
        self.displayName = displayName; self.memoryMB = memoryMB; self.cpuCores = cpuCores
        self.width = width; self.height = height; self.density = density
    }

    public var validationError: String? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a display name for this phone." }
        if name.count > 128 { return "Keep the display name to 128 characters or fewer." }
        if displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
            return "The display name cannot contain line breaks or control characters."
        }
        if !(512...16384).contains(memoryMB) { return "Memory must be between 512 and 16384 MB." }
        if !(1...16).contains(cpuCores) { return "CPU cores must be between 1 and 16." }
        if !(240...4096).contains(width) { return "Screen width must be between 240 and 4096 pixels." }
        if !(240...4096).contains(height) { return "Screen height must be between 240 and 4096 pixels." }
        if !width.isMultiple(of: 2) || !height.isMultiple(of: 2) { return "Screen width and height must be even numbers." }
        if !(120...640).contains(density) { return "Screen density must be between 120 and 640 DPI." }
        return nil
    }

    fileprivate var values: [(String, String)] {
        [("avd.ini.displayname", displayName.trimmingCharacters(in: .whitespacesAndNewlines)),
         ("hw.ramSize", String(memoryMB)), ("hw.cpu.ncore", String(cpuCores)),
         ("hw.lcd.width", String(width)), ("hw.lcd.height", String(height)),
         ("hw.lcd.density", String(density))]
    }
}

/// An immutable snapshot ties Save to the exact file opened by the editor.
public struct AVDConfigurationDocument: Sendable {
    public let url: URL
    public let configuration: AVDConfiguration
    fileprivate let snapshot: ConfigurationSnapshot
}

public enum AVDConfigurationError: LocalizedError, Equatable {
    case missingConfiguration
    case unsafeFile
    case oversizedFile
    case invalidEncoding
    case invalidValue(String)
    case changedOnDisk
    case notWritable
    case deviceInUse

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "This phone does not have an accessible config.ini file."
        case .unsafeFile: return "The phone configuration must be a regular file, not a symbolic link or folder."
        case .oversizedFile: return "The phone configuration is too large to edit safely."
        case .invalidEncoding: return "The phone configuration is not valid UTF-8 text."
        case .invalidValue(let message): return message
        case .changedOnDisk: return "The configuration changed after you opened it. Close the editor and reopen it before saving."
        case .notWritable: return "The phone configuration is read-only. Check its file permissions before saving."
        case .deviceInUse: return "This phone may still be in use. Stop its emulator, then try again."
        }
    }
}

public enum AVDConfigurationStore {
    private static let maximumBytes = 1_048_576

    public static func load(avd: AVD) throws -> AVDConfigurationDocument {
        guard let url = avd.configURL, url.isFileURL else { throw AVDConfigurationError.missingConfiguration }
        let normalized = url.standardizedFileURL
        try requireStoppedDevice(at: normalized)
        let descriptor = try openConfiguration(normalized)
        defer { Darwin.close(descriptor) }
        let snapshot = try readSnapshot(descriptor)
        let lines = try ConfigurationLine.parse(snapshot.bytes)
        var values: [String: String] = [:]
        for line in lines {
            if let assignment = line.assignment { values[assignment.key] = assignment.value }
        }
        func number(_ key: String, fallback: Int) throws -> Int {
            guard let value = values[key] else { return fallback }
            guard let number = Int(value) else {
                throw AVDConfigurationError.invalidValue("The configuration value for \(key) must be a whole number.")
            }
            return number
        }
        let configuration = try AVDConfiguration(
            displayName: values["avd.ini.displayname"] ?? avd.displayName,
            memoryMB: number("hw.ramSize", fallback: avd.memoryMB > 0 ? avd.memoryMB : 2048),
            cpuCores: number("hw.cpu.ncore", fallback: 4),
            width: number("hw.lcd.width", fallback: 1080),
            height: number("hw.lcd.height", fallback: 2400),
            density: number("hw.lcd.density", fallback: 420))
        return AVDConfigurationDocument(url: normalized, configuration: configuration, snapshot: snapshot)
    }

    /// AppModel checks whether the device is stopped immediately before calling
    /// this method. Unknown settings, comments, and unchanged values stay intact.
    public static func save(_ configuration: AVDConfiguration, document: AVDConfigurationDocument) throws {
        if let error = configuration.validationError { throw AVDConfigurationError.invalidValue(error) }
        try requireStoppedDevice(at: document.url)
        let descriptor = try openConfiguration(document.url)
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AVDConfigurationError.deviceInUse }
        defer { flock(descriptor, LOCK_UN) }
        let current = try readSnapshot(descriptor)
        guard current.matches(document.snapshot) else { throw AVDConfigurationError.changedOnDisk }
        let originals = Dictionary(uniqueKeysWithValues: document.configuration.values)
        let changes = configuration.values.filter { originals[$0.0] != $0.1 }
        guard !changes.isEmpty else { return }
        guard current.permissions & 0o222 != 0, Darwin.access(document.url.path, W_OK) == 0 else {
            throw AVDConfigurationError.notWritable
        }
        var lines = try ConfigurationLine.parse(current.bytes)
        let newline = lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
        var pending = Dictionary(uniqueKeysWithValues: changes)
        for index in lines.indices {
            guard let assignment = lines[index].assignment, let value = pending[assignment.key] else { continue }
            // Retain indentation, key spelling, spacing around '=', and any
            // trailing whitespace. Every duplicate of a changed key is updated.
            lines[index].body = assignment.prefix + value + assignment.suffix
        }
        for line in lines {
            if let key = line.assignment?.key { pending.removeValue(forKey: key) }
        }
        for (key, value) in changes where pending[key] != nil {
            if let last = lines.indices.last, lines[last].ending.isEmpty { lines[last].ending = newline }
            lines.append(ConfigurationLine(body: "\(key)=\(value)", ending: newline))
        }
        let updated = Data(lines.map { $0.body + $0.ending }.joined().utf8)
        guard updated.count <= maximumBytes else { throw AVDConfigurationError.oversizedFile }
        try atomicReplace(updated, document: document, current: current, descriptor: descriptor)
    }

    /// Emulator PID markers can survive shutdown. Recognized records are stale
    /// only when their owner is definitively gone and no kernel lock is held.
    /// The multiinstance file persists normally, so only its held lock counts.
    /// This check supplements the caller's fresh ADB/session check; it does not
    /// reserve a device against another app launching it immediately afterward.
    public static func requireStoppedDevice(at configURL: URL) throws {
        guard configURL.isFileURL else { throw AVDConfigurationError.missingConfiguration }
        let directory = configURL.deletingLastPathComponent()
        for name in ["hardware-qemu.ini.lock", "userdata-qemu.img.lock", "snapshot.lock.lock"] {
            try requireStaleOwnerMarker(at: directory.appendingPathComponent(name))
        }
        let lockURL = directory.appendingPathComponent("multiinstance.lock")
        let descriptor = Darwin.open(lockURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw AVDConfigurationError.deviceInUse
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AVDConfigurationError.deviceInUse }
        var recordLock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(descriptor, F_GETLK, &recordLock) == 0, recordLock.l_type == Int16(F_UNLCK),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AVDConfigurationError.deviceInUse }
        flock(descriptor, LOCK_UN)
    }

    private static func requireStaleOwnerMarker(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw AVDConfigurationError.deviceInUse
        }
        defer { Darwin.close(descriptor) }
        let original = try readOwnerMarker(descriptor, at: url)
        // Support only the observed emulator format: decimal PID and one NUL.
        // Empty, partially written, legacy directory, or unknown records block.
        let digits = original.bytes.dropLast()
        guard original.bytes.last == 0, !digits.isEmpty, digits.first != 48,
              digits.allSatisfy({ (48...57).contains($0) }),
              let pid = Int32(String(decoding: digits, as: UTF8.self)), pid > 0 else {
            throw AVDConfigurationError.deviceInUse
        }
        var recordLock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(descriptor, F_GETLK, &recordLock) == 0, recordLock.l_type == Int16(F_UNLCK),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AVDConfigurationError.deviceInUse }
        defer { flock(descriptor, LOCK_UN) }
        guard Darwin.kill(pid, 0) == -1, errno == ESRCH else { throw AVDConfigurationError.deviceInUse }
        let current = try readOwnerMarker(descriptor, at: url)
        // On Darwin F_GETLK reports this descriptor's flock as a conflict
        // (l_pid == -1), so inspect record locks before acquiring the flock.
        guard current.bytes == original.bytes, sameMarker(original.info, current.info),
              Darwin.kill(pid, 0) == -1, errno == ESRCH else { throw AVDConfigurationError.deviceInUse }
        // Inspection never unlinks or rewrites the emulator's marker.
    }

    private static func readOwnerMarker(_ descriptor: Int32, at url: URL) throws -> (bytes: Data, info: stat) {
        var before = stat(), after = stat(), path = stat()
        // Int32's maximum decimal PID plus its NUL fits in eleven bytes. A
        // twelve-byte read also detects a record that grows during inspection.
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              (2...11).contains(before.st_size) else { throw AVDConfigurationError.deviceInUse }
        var buffer = [UInt8](repeating: 0, count: 12)
        var count: Int
        repeat {
            count = buffer.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, $0.count, 0) }
        } while count < 0 && errno == EINTR
        guard count == before.st_size, fstat(descriptor, &after) == 0,
              lstat(url.path, &path) == 0, sameMarker(before, after), sameMarker(after, path) else {
            throw AVDConfigurationError.deviceInUse
        }
        return (Data(buffer.prefix(count)), after)
    }

    private static func sameMarker(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode &&
        lhs.st_size == rhs.st_size && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
        lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
        lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func openConfiguration(_ url: URL) throws -> Int32 {
        // O_NONBLOCK prevents an unexpected FIFO from blocking before fstat.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw AVDConfigurationError.unsafeFile }
            throw AVDConfigurationError.missingConfiguration
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { Darwin.close(descriptor); throw AVDConfigurationError.missingConfiguration }
        guard info.st_mode & S_IFMT == S_IFREG else { Darwin.close(descriptor); throw AVDConfigurationError.unsafeFile }
        return descriptor
    }

    private static func readSnapshot(_ descriptor: Int32) throws -> ConfigurationSnapshot {
        var before = stat()
        guard fstat(descriptor, &before) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw AVDConfigurationError.missingConfiguration
        }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw AVDConfigurationError.oversizedFile }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AVDConfigurationError.missingConfiguration
            }
            guard data.count + count <= maximumBytes else { throw AVDConfigurationError.oversizedFile }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw AVDConfigurationError.changedOnDisk
        }
        return ConfigurationSnapshot(bytes: data, device: UInt64(after.st_dev), inode: UInt64(after.st_ino),
                                     permissions: after.st_mode & 0o7777)
    }

    private static func atomicReplace(_ bytes: Data, document: AVDConfigurationDocument,
                                      current: ConfigurationSnapshot, descriptor: Int32) throws {
        let temporary = document.url.deletingLastPathComponent()
            .appendingPathComponent(".droiddock-config-\(UUID().uuidString).tmp")
        let output = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(output); try? FileManager.default.removeItem(at: temporary) }
        try bytes.withUnsafeBytes { data in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(output, data.baseAddress?.advanced(by: offset), data.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fchmod(output, current.permissions) == 0, fsync(output) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Check again after preparing the replacement. Neither a changed file
        // nor a replacement symlink may be silently overwritten by this editor.
        var pathInfo = stat()
        guard lstat(document.url.path, &pathInfo) == 0, pathInfo.st_mode & S_IFMT == S_IFREG,
              UInt64(pathInfo.st_dev) == current.device, UInt64(pathInfo.st_ino) == current.inode,
              try readSnapshot(descriptor).matches(current) else { throw AVDConfigurationError.changedOnDisk }
        try requireStoppedDevice(at: document.url)
        guard Darwin.rename(temporary.path, document.url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

fileprivate struct ConfigurationSnapshot: Sendable {
    let bytes: Data
    let device: UInt64
    let inode: UInt64
    let permissions: mode_t

    func matches(_ other: ConfigurationSnapshot) -> Bool {
        bytes == other.bytes && device == other.device && inode == other.inode && permissions == other.permissions
    }
}

private struct ConfigurationLine {
    var body: String
    var ending: String

    var assignment: (key: String, value: String, prefix: String, suffix: String)? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let equal = body.firstIndex(of: "=") else { return nil }
        let key = body[..<equal].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let rawValue = body[body.index(after: equal)...]
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        let leading = rawValue.prefix(while: { $0.isWhitespace })
        let trailing = rawValue.dropFirst(leading.count).reversed().prefix(while: { $0.isWhitespace }).reversed()
        return (key, value, String(body[...equal]) + leading, String(trailing))
    }

    static func parse(_ data: Data) throws -> [ConfigurationLine] {
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else { throw AVDConfigurationError.invalidEncoding }
        let bytes = Array(data)
        var lines: [ConfigurationLine] = []
        var start = 0, index = 0
        while index < bytes.count {
            if bytes[index] == 10 || bytes[index] == 13 {
                let end = index
                if bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                index += 1
                lines.append(.init(body: String(decoding: bytes[start..<end], as: UTF8.self),
                                   ending: String(decoding: bytes[end..<index], as: UTF8.self)))
                start = index
            } else { index += 1 }
        }
        if start < bytes.count { lines.append(.init(body: String(decoding: bytes[start...], as: UTF8.self), ending: "")) }
        return lines
    }
}

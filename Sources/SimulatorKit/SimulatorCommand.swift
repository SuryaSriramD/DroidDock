import Foundation
import Darwin

public enum SimulatorCommandAction: String, Codable, Sendable {
    case list, status, boot, open, stop, install
    case openURL = "open-url"
}

public enum SimulatorCommandError: LocalizedError, Sendable {
    case invalidRequest(String)
    case expired
    case unavailable(String)
    case unsafeFile(String)
    case duplicate

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): return detail
        case .expired: return "The terminal command expired. Run it again when the app is ready."
        case .unavailable(let detail): return "Terminal command transport is unavailable: \(detail)"
        case .unsafeFile(let detail): return "Terminal command file was rejected: \(detail)"
        case .duplicate: return "This terminal command has already been received."
        }
    }
}

public struct SimulatorCommandRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let id: UUID
    public let action: SimulatorCommandAction
    public let device: String?
    public let argument: String?
    public let createdAt: Date
    public let expiresAt: Date
    public static let maximumTimeout: TimeInterval = 600

    public init(id: UUID = UUID(), action: SimulatorCommandAction, device: String? = nil,
                argument: String? = nil, timeout: TimeInterval = 120, createdAt: Date = Date()) {
        version = 1
        self.id = id
        self.action = action
        self.device = device
        self.argument = argument
        self.createdAt = createdAt
        expiresAt = createdAt.addingTimeInterval(timeout)
    }

    @discardableResult
    public func validated(now: Date = Date()) throws -> Self {
        let lifetime = expiresAt.timeIntervalSince(createdAt)
        guard version == 1, createdAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite, lifetime >= 1,
              lifetime <= Self.maximumTimeout, createdAt <= now.addingTimeInterval(5) else {
            throw SimulatorCommandError.invalidRequest("Unsupported command version or invalid command deadline.")
        }
        guard expiresAt > now else { throw SimulatorCommandError.expired }
        if let device {
            guard !device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  device.utf8.count <= 512, !device.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw SimulatorCommandError.invalidRequest("Provide a device name or ID from droiddock list.")
            }
        }
        switch action {
        case .list:
            guard device == nil, argument == nil else { throw SimulatorCommandError.invalidRequest("list does not take a device or argument.") }
        case .status, .boot, .open:
            guard argument == nil else { throw SimulatorCommandError.invalidRequest("\(action.rawValue) does not take an extra argument.") }
        case .stop:
            guard device != nil, argument == nil else { throw SimulatorCommandError.invalidRequest("stop requires one device name or ID.") }
        case .install:
            guard device != nil, let argument, argument.hasPrefix("/"), argument.utf8.count <= 4_096,
                  !argument.contains("\0"), URL(fileURLWithPath: argument).pathExtension.lowercased() == "apk" else {
                throw SimulatorCommandError.invalidRequest("install requires a device and an absolute APK file path.")
            }
        case .openURL:
            guard device != nil, let argument, Self.isValidLaunchURL(argument) else {
                throw SimulatorCommandError.invalidRequest("open-url requires a device and a URL with a valid scheme, such as exp://, https:// or your app's custom scheme.")
            }
        }
        return self
    }

    public func remainingTime(now: Date = Date()) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }

    public static func isValidLaunchURL(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 8_192,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: value), let scheme = components.scheme,
              components.url != nil, scheme.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil else { return false }
        // File/content URLs are local resources, not app-testing deep links.
        return !["file", "content", "javascript", "data", "droiddock", "android-simulator"].contains(scheme.lowercased())
    }
}

public struct SimulatorCommandDevice: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let state: String
    public let serial: String?
    public let pid: Int32?
    public let sdkPath: String?
    public let isOwned: Bool

    public init(id: String, name: String, state: String, serial: String? = nil,
                pid: Int32? = nil, sdkPath: String? = nil, isOwned: Bool = false) {
        self.id = id; self.name = name; self.state = state; self.serial = serial
        self.pid = pid; self.sdkPath = sdkPath; self.isOwned = isOwned
    }
}

public struct SimulatorCommandResponse: Codable, Sendable, Equatable {
    public let version: Int
    public let id: UUID
    public let success: Bool
    public let message: String
    public let devices: [SimulatorCommandDevice]
    public let errorCode: String?

    public init(id: UUID, success: Bool, message: String, devices: [SimulatorCommandDevice] = [], errorCode: String? = nil) {
        version = 1; self.id = id; self.success = success; self.message = message
        self.devices = devices; self.errorCode = errorCode
    }
}

/// A small local mailbox shared by the terminal client and its native GUI.
/// All leaf operations use a verified directory descriptor and never follow
/// symlinks. The URL carries only an ID; no caller-chosen file path is accepted.
public struct SimulatorCommandStore: Sendable {
    public static let maximumFileBytes = 128 * 1_024
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AndroidSimulator/Commands", isDirectory: true)
    }
    public let directory: URL
    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }

    public static func commandURL(id: UUID) -> URL {
        makeCommandURL(id: id, scheme: "droiddock")
    }

    /// Older app bundles understand the same mailbox protocol under the legacy
    /// wake-up scheme. Prefer the new scheme when both are registered.
    public static func compatibleCommandURL(id: UUID, registeredSchemes: [String]) -> URL? {
        for scheme in ["droiddock", "android-simulator"] where registeredSchemes.contains(scheme) {
            return makeCommandURL(id: id, scheme: scheme)
        }
        return nil
    }

    private static func makeCommandURL(id: UUID, scheme: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "command"
        components.path = "/\(id.uuidString)"
        return components.url!
    }

    public static func requestID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["droiddock", "android-simulator"].contains(components.scheme ?? ""), components.host == "command",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == components.path,
              components.path.count == 37, components.path.first == "/" else { return nil }
        return UUID(uuidString: String(components.path.dropFirst()))
    }

    public func createRequest(_ request: SimulatorCommandRequest, now: Date = Date()) throws {
        try request.validated(now: now)
        try withDirectory { descriptor in
            try write(request, name: name(request.id, "request.json"), directoryFD: descriptor)
        }
    }

    /// Moves a request into a single-use claim. A replay can never run it a
    /// second time while the client waits for its response.
    public func consumeRequest(id: UUID, now: Date = Date()) throws -> SimulatorCommandRequest {
        try withDirectory { descriptor in
            let requestName = name(id, "request.json")
            guard let data = try read(name: requestName, directoryFD: descriptor) else {
                throw SimulatorCommandError.invalidRequest("The terminal request no longer exists. Run the command again.")
            }
            let request = try JSONDecoder().decode(SimulatorCommandRequest.self, from: data)
            guard request.id == id else { throw SimulatorCommandError.invalidRequest("The terminal request ID does not match its filename.") }
            try request.validated(now: now)
            let claim = name(id, "claimed")
            // linkat provides an exclusive claim only when the source still
            // exists. An arbitrary URL or concurrent client cleanup cannot
            // create an empty orphan claim.
            guard linkat(descriptor, requestName, descriptor, claim, 0) == 0 else {
                if errno == EEXIST { throw SimulatorCommandError.duplicate }
                throw systemError()
            }
            unlinkat(descriptor, requestName, 0)
            guard let claimedData = try read(name: claim, directoryFD: descriptor), claimedData == data else {
                unlinkat(descriptor, claim, 0)
                throw SimulatorCommandError.invalidRequest("The terminal request changed while being received.")
            }
            return request
        }
    }

    public func writeResponse(_ response: SimulatorCommandResponse) throws {
        try withDirectory { descriptor in
            // Coordinate with client cleanup. A timed-out/closed client leaves
            // no late response behind, even when a GUI operation finishes later.
            let exists = try withClaim(id: response.id, directoryFD: descriptor) {
                try write(response, name: name(response.id, "response.json"), directoryFD: descriptor)
            }
            guard exists else { throw SimulatorCommandError.expired }
        }
    }

    public func readResponse(id: UUID) throws -> SimulatorCommandResponse? {
        try withDirectory { descriptor in
            guard let data = try read(name: name(id, "response.json"), directoryFD: descriptor) else { return nil }
            let response = try JSONDecoder().decode(SimulatorCommandResponse.self, from: data)
            guard response.version == 1, response.id == id else {
                throw SimulatorCommandError.invalidRequest("The terminal response has a different request ID or protocol version.")
            }
            return response
        }
    }

    /// Removes only this invocation's fixed filenames. Expired requests are
    /// rejected by the receiver even if a client is killed before this cleanup.
    public func remove(id: UUID) throws {
        try withDirectory { descriptor in
            // Remove the source first, so no new claim can appear after the
            // subsequent lock lookup.
            try removeFile(name(id, "request.json"), directoryFD: descriptor)
            let claimed = try withClaim(id: id, directoryFD: descriptor) {
                try removeFile(name(id, "response.json"), directoryFD: descriptor)
                try removeFile(name(id, "claimed"), directoryFD: descriptor)
            }
            if !claimed { try removeFile(name(id, "response.json"), directoryFD: descriptor) }
        }
    }

    private func removeFile(_ name: String, directoryFD: Int32) throws {
        if unlinkat(directoryFD, name, 0) != 0, errno != ENOENT { throw systemError() }
    }

    private func withClaim(id: UUID, directoryFD: Int32, body: () throws -> Void) throws -> Bool {
        let claim = name(id, "claimed")
        let descriptor = openat(directoryFD, claim, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw systemError()
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw systemError() }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600 else {
            throw SimulatorCommandError.unsafeFile("The command claim is not an owner-only regular file.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else { throw systemError() }
            usleep(5_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        var current = stat()
        guard fstatat(directoryFD, claim, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == metadata.st_dev, current.st_ino == metadata.st_ino else { return false }
        try body()
        return true
    }

    private func name(_ id: UUID, _ suffix: String) -> String { "\(id.uuidString).\(suffix)" }

    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        guard directory.isFileURL else { throw SimulatorCommandError.unsafeFile("A local command directory is required.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError() }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw systemError() }
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw SimulatorCommandError.unsafeFile("The Commands directory must belong to this user and have permissions 0700.")
        }
        return try body(descriptor)
    }

    private func read(name: String, directoryFD: Int32) throws -> Data? {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw systemError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw systemError() }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == 0o600, metadata.st_nlink == 1,
              metadata.st_size >= 0, metadata.st_size <= Self.maximumFileBytes else {
            throw SimulatorCommandError.unsafeFile("Expected a single-link, owner-only regular file no larger than 128 KiB.")
        }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw SimulatorCommandError.unsafeFile("The command exceeds 128 KiB.") }
        return data
    }

    private func write<T: Encodable>(_ value: T, name: String, directoryFD: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumFileBytes else { throw SimulatorCommandError.unsafeFile("The command exceeds 128 KiB.") }
        var existing = stat()
        guard fstatat(directoryFD, name, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw SimulatorCommandError.duplicate
        }
        let temporary = ".\(UUID().uuidString).tmp"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw systemError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(directoryFD, temporary, 0) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw systemError() }
    }

    private func systemError() -> SimulatorCommandError { .unavailable(String(cString: strerror(errno))) }
}

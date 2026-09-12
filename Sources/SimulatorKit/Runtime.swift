import Foundation
import Darwin

public enum SDKLocator {
    public static func resolve(explicitPath: String? = nil) throws -> SDKInstallation {
        if let path = explicitPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return try validate(path: path)
        }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"],
                          "\(home)/Library/Android/sdk", "\(home)/Android/Sdk"]
        for case let path? in candidates where !path.isEmpty {
            if let sdk = try? validate(path: path) { return sdk }
        }
        throw RuntimeError.sdkNotFound
    }

    public static func validate(path: String) throws -> SDKInstallation {
        let expanded = NSString(string: path).expandingTildeInPath
        let root = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let emulator = root.appendingPathComponent("emulator/emulator")
        let adb = root.appendingPathComponent("platform-tools/adb")
        for (url, component) in [(emulator, "emulator/emulator"), (adb, "platform-tools/adb")] {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
                throw RuntimeError.invalidSDK(path: root.path, missing: component)
            }
        }
        return SDKInstallation(root: root, emulator: emulator, adb: adb)
    }
}

public enum AVDRepository {
    public static func discover(sdk: SDKInstallation) async throws -> [AVD] {
        let result = try await ProcessRunner.run(executable: sdk.emulator, arguments: ["-list-avds"])
        try result.requireSuccess(operation: "List virtual devices")
        let names = Set(result.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isValidName($0) })
        return names.map { metadata(name: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 255 && name.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        } && name != "." && name != ".." && !name.hasPrefix("-")
    }

    /// Exposed for metadata tests and diagnostics; reads existing AVD files only.
    public static func metadata(name: String, searchDirectories: [URL]? = nil) -> AVD {
        guard isValidName(name) else { return AVD(name: name) }
        for directory in searchDirectories ?? avdDirectories() {
            let indexURL = directory.appendingPathComponent("\(name).ini")
            let index = readINI(at: indexURL)
            let configDirectory: URL
            if let path = index["path"], !path.isEmpty {
                configDirectory = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
            } else if let relative = index["path.rel"], !relative.isEmpty {
                configDirectory = directory.deletingLastPathComponent().appendingPathComponent(relative, isDirectory: true)
            } else {
                configDirectory = directory.appendingPathComponent("\(name).avd", isDirectory: true)
            }
            let configURL = configDirectory.appendingPathComponent("config.ini")
            let config = readINI(at: configURL)
            guard !config.isEmpty || !index.isEmpty else { continue }
            let imageAPI = config["image.sysdir.1"]?.split(separator: "/")
                .first { $0.hasPrefix("android-") }.map(String.init)
            let target = config["target"] ?? index["target"] ?? imageAPI ?? "Unknown"
            let api = target.hasPrefix("android-") ? String(target.dropFirst(8)) : target
            let resolution: String
            if let width = config["hw.lcd.width"], let height = config["hw.lcd.height"] {
                resolution = "\(width) × \(height)"
            } else { resolution = "Unknown" }
            return AVD(name: name, displayName: config["avd.ini.displayname"], apiLevel: api,
                       architecture: config["abi.type"] ?? config["hw.cpu.arch"] ?? "Unknown",
                       resolution: resolution, memoryMB: Int(config["hw.ramSize"] ?? "") ?? 0,
                       configURL: FileManager.default.fileExists(atPath: configURL.path) ? configURL : nil)
        }
        return AVD(name: name)
    }

    public static func readINI(at url: URL) -> [String: String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue < 1_048_576,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return contents.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
                  let separator = trimmed.firstIndex(of: "=") else { return }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
    }

    private static func avdDirectories() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let path = environment["ANDROID_AVD_HOME"] { candidates.append(URL(fileURLWithPath: path)) }
        if let path = environment["ANDROID_USER_HOME"] { candidates.append(URL(fileURLWithPath: path).appendingPathComponent("avd")) }
        if let path = environment["ANDROID_EMULATOR_HOME"] { candidates.append(URL(fileURLWithPath: path).appendingPathComponent("avd")) }
        if let path = environment["ANDROID_SDK_HOME"] { candidates.append(URL(fileURLWithPath: path).appendingPathComponent(".android/avd")) }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd"))
        return candidates
    }
}

public struct ADBService: Sendable {
    public let sdk: SDKInstallation
    public let serial: String

    public init(sdk: SDKInstallation, serial: String) {
        self.sdk = sdk
        self.serial = serial
    }

    public func run(_ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        guard !serial.isEmpty, !serial.contains("\0") else {
            throw RuntimeError.invalidArgument("A device serial is required for ADB commands.")
        }
        let result = try await ProcessRunner.run(executable: sdk.adb, arguments: ["-s", serial] + arguments, timeout: timeout)
        try result.requireSuccess(operation: "ADB \(arguments.first ?? "command")")
        return result
    }

    public func shell(_ arguments: [String]) async throws -> String {
        try await run(Self.shellArguments(for: arguments)).text
    }

    /// adb joins its shell arguments into a remote shell command. Quote every
    /// token there as well as using argument arrays for the local Process.
    public static func shellArguments(for arguments: [String]) -> [String] {
        let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return ["shell", quoted.joined(separator: " ")]
    }

    public func install(apk: URL) async throws {
        guard apk.isFileURL, apk.pathExtension.lowercased() == "apk",
              FileManager.default.isReadableFile(atPath: apk.path) else {
            throw RuntimeError.invalidArgument("Choose a readable .apk file to install.")
        }
        let result = try await run(["install", "-r", apk.path], timeout: 180)
        guard result.text.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Success" }) else {
            throw RuntimeError.commandFailed(operation: "Install APK", status: result.status, details: result.text + result.stderrText)
        }
    }

    public func screenshot(to url: URL) async throws {
        let result = try await run(["exec-out", "screencap", "-p"], timeout: 20)
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard result.stdout.starts(with: pngSignature) else {
            throw RuntimeError.invalidArgument("The device did not return a valid PNG screenshot. Check that Android has booted and try again.")
        }
        try result.stdout.write(to: url, options: .atomic)
    }

    public static func devices(sdk: SDKInstallation) async throws -> [ADBDevice] {
        let result = try await ProcessRunner.run(executable: sdk.adb, arguments: ["devices", "-l"], timeout: 12)
        try result.requireSuccess(operation: "List ADB devices")
        let devices = parseDevices(result.text)
        return await withTaskGroup(of: ADBDevice.self) { group in
            for device in devices {
                group.addTask {
                    guard device.serial.hasPrefix("emulator-"), device.state == "device" else { return device }
                    let adb = ADBService(sdk: sdk, serial: device.serial)
                    guard let result = try? await adb.run(["emu", "avd", "name"], timeout: 3) else { return device }
                    let name = result.text.split(whereSeparator: \.isNewline).map(String.init)
                        .first { !$0.isEmpty && $0 != "OK" && AVDRepository.isValidName($0) }
                    return ADBDevice(serial: device.serial, state: device.state, avdName: name)
                }
            }
            var discovered: [ADBDevice] = []
            for await device in group { discovered.append(device) }
            return discovered.sorted { $0.serial < $1.serial }
        }
    }

    public static func parseDevices(_ text: String) -> [ADBDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2, columns[0] != "List", !line.hasPrefix("*") else { return nil }
            let state = String(columns[1])
            guard ["device", "offline", "unauthorized", "recovery", "bootloader", "sideload", "no"].contains(state) else { return nil }
            return ADBDevice(serial: String(columns[0]), state: state == "no" ? "no permissions" : state)
        }
    }
}

public struct RunningEmulator: Identifiable, @unchecked Sendable {
    public let process: Process
    public let serial: String
    public let consolePort: Int
    public let avdName: String
    public let logURL: URL
    public let id: UUID
    private let logDrain: RuntimeLogDrain?

    init(process: Process, serial: String, consolePort: Int, avdName: String, logURL: URL,
         id: UUID, logDrain: RuntimeLogDrain? = nil) {
        self.process = process; self.serial = serial; self.consolePort = consolePort
        self.avdName = avdName; self.logURL = logURL; self.id = id; self.logDrain = logDrain
    }

    /// Wait for the owned pipe reader to consume EOF and close its output file.
    /// Cancellation does not skip this bounded cleanup; no process is signalled.
    /// False means EOF was not confirmed, so a captured log may be incomplete.
    public func waitForLogDrain(timeout: TimeInterval = 2) async -> Bool {
        guard let logDrain else { return false }
        return await logDrain.wait(timeout: timeout)
    }
}

/// Owns only children launched by this instance. Matching an AVD name or an ADB
/// serial never grants ownership of an independently running emulator.
public final class EmulatorProcessManager: @unchecked Sendable {
    private let lock = NSLock()
    private var owned: [UUID: RunningEmulator] = [:]
    private var starting: Set<String> = []
    private let logDirectoryOverride: URL?

    public init(logDirectory: URL? = nil) { self.logDirectoryOverride = logDirectory }

    /// Wiping is destructive and must be explicitly confirmed by the caller's
    /// product UI. It never bypasses the refusal to launch an already-used AVD.
    public func launch(sdk: SDKInstallation, avd: AVD, coldBoot: Bool = false, gpuMode: String = "host", wipeData: Bool = false) async throws -> RunningEmulator {
        guard AVDRepository.isValidName(avd.name) else { throw RuntimeError.invalidArgument("The AVD name is invalid.") }
        try Self.validateGPUMode(gpuMode)
        try checkArchitecture(avd.architecture)
        try lock.withLock {
            guard !starting.contains(avd.name), !owned.values.contains(where: { $0.avdName == avd.name && $0.process.isRunning }) else {
                throw RuntimeError.avdAlreadyRunning(avd.displayName)
            }
            starting.insert(avd.name)
        }
        defer { _ = lock.withLock { starting.remove(avd.name) } }
        let externalDevices = try await ADBService.devices(sdk: sdk)
        guard !externalDevices.contains(where: { $0.avdName == avd.name }) else {
            throw RuntimeError.avdAlreadyRunning(avd.displayName)
        }
        try Task.checkCancellation()
        let reservation = try PortReservation.reserve()
        let id = UUID()
        let logDirectory = logDirectoryOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AndroidSimulator", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent("\(avd.name)-\(id.uuidString).log")
        let logger = try EmulatorLog(url: logURL)
        let process = Process()
        process.executableURL = sdk.emulator
        process.arguments = try Self.launchArguments(avd: avd, consolePort: reservation.port, coldBoot: coldBoot, gpuMode: gpuMode, wipeData: wipeData)
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_HOME"] = sdk.root.path
        environment["ANDROID_SDK_ROOT"] = sdk.root.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logger.output
        process.standardError = logger.output
        let runtime = RunningEmulator(process: process, serial: "emulator-\(reservation.port)",
                                      consolePort: reservation.port, avdName: avd.name, logURL: logURL, id: id,
                                      logDrain: logger.completion)
        process.terminationHandler = { [weak self, logger, reservation] _ in
            logger.finish()
            reservation.release()
            _ = self?.lock.withLock { self?.owned.removeValue(forKey: id) }
        }
        // TCP reservations and the in-app registry cover other app sessions.
        // The OS socket must be released immediately before emulator binds it.
        reservation.closeSockets()
        do {
            try process.run()
            logger.begin()
        } catch {
            logger.finish()
            reservation.release()
            throw error
        }
        lock.withLock { owned[id] = runtime }
        if Task.isCancelled {
            await stop(runtime)
            throw CancellationError()
        }
        return runtime
    }

    public static func launchArguments(avd: AVD, consolePort: Int, coldBoot: Bool = false, gpuMode: String = "host", wipeData: Bool = false) throws -> [String] {
        try validateGPUMode(gpuMode)
        // Explicit host keeps hardware rendering in headless mode. Emulator
        // automatic selection otherwise chooses software when there is no window.
        var arguments = ["-avd", avd.name, "-no-window", "-port", String(consolePort), "-gpu", gpuMode]
        if wipeData { arguments.append("-wipe-data") }
        if coldBoot || wipeData { arguments.append("-no-snapshot-load") }
        return arguments
    }

    private static func validateGPUMode(_ mode: String) throws {
        guard ["host", "auto", "software"].contains(mode) else {
            throw RuntimeError.invalidArgument("Unsupported graphics mode. Choose host, auto, or software rendering.")
        }
    }

    public func stop(_ runtime: RunningEmulator) async {
        let isOwned = lock.withLock { owned[runtime.id]?.process === runtime.process }
        guard isOwned, runtime.process.isRunning else { return }
        // SIGTERM is handled by the emulator and allows it to save Quick Boot.
        // No serial-based ADB kill is used: the serial could be reassigned.
        runtime.process.terminate()
        for _ in 0..<80 {
            if !runtime.process.isRunning { return }
            // Shutdown must retain its grace period even when a launch task
            // was cancelled; Task.sleep would throw immediately in that case.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
            }
        }
        let stillOwned = lock.withLock { owned[runtime.id]?.process === runtime.process }
        if stillOwned, runtime.process.isRunning {
            Darwin.kill(runtime.process.processIdentifier, SIGKILL)
            // Foundation observes/reaps child exit asynchronously. Do not hand
            // a restart back to the caller while the killed child is still
            // reported running or its console port is not yet released.
            for _ in 0..<20 {
                if !runtime.process.isRunning { return }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
                }
            }
        }
    }

    private func checkArchitecture(_ architecture: String) throws {
        #if arch(arm64)
        if architecture.lowercased().contains("x86") { throw RuntimeError.architectureMismatch(architecture) }
        #elseif arch(x86_64)
        if architecture.lowercased().contains("arm64") { throw RuntimeError.architectureMismatch(architecture) }
        #endif
    }
}

private final class PortReservation: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var reserved: Set<Int> = []
    let port: Int
    private let lock = NSLock()
    private var sockets: [Int32]
    private var released = false

    private init(port: Int, sockets: [Int32]) {
        self.port = port
        self.sockets = sockets
    }

    static func reserve() throws -> PortReservation {
        try registryLock.withLock {
            for port in stride(from: 5554, through: 5682, by: 2) where !reserved.contains(port) {
                guard let first = bindPort(port) else { continue }
                guard let second = bindPort(port + 1) else { Darwin.close(first); continue }
                reserved.insert(port)
                return PortReservation(port: port, sockets: [first, second])
            }
            throw RuntimeError.noAvailablePorts
        }
    }

    func closeSockets() {
        lock.withLock {
            for socket in sockets { Darwin.close(socket) }
            sockets.removeAll()
        }
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            for socket in sockets { Darwin.close(socket) }
            sockets.removeAll()
            return true
        }
        if shouldRelease { _ = Self.registryLock.withLock { Self.reserved.remove(port) } }
    }

    deinit { release() }

    private static func bindPort(_ port: Int) -> Int32? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { Darwin.close(descriptor); return nil }
        return descriptor
    }
}

/// A cancellation-independent completion signal with bounded, race-safe waits.
final class RuntimeLogDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func complete() {
        let pending = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            guard !finished else { return [] }
            finished = true
            let pending = Array(waiters.values); waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: true) }
    }

    func wait(timeout: TimeInterval) async -> Bool {
        let delay = timeout.isFinite ? min(30, max(0, timeout)) : 2
        return await withCheckedContinuation { continuation in
            let id = UUID()
            let alreadyFinished = lock.withLock {
                if finished { return true }
                waiters[id] = continuation
                return false
            }
            if alreadyFinished { continuation.resume(returning: true); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
                let pending = lock.withLock { waiters.removeValue(forKey: id) }
                pending?.resume(returning: false)
            }
        }
    }
}

/// Keep process diagnostics bounded even if a broken emulator logs endlessly.
final class EmulatorLog: @unchecked Sendable {
    let output = Pipe()
    let completion = RuntimeLogDrain()
    private let queue = DispatchQueue(label: "app.androidsimulator.runtime-log")
    private let handle: FileHandle
    private var written = 0
    private let limit = 8 * 1_024 * 1_024

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func begin() {
        try? output.fileHandleForWriting.close()
        queue.async { [self] in
            defer {
                try? output.fileHandleForReading.close(); try? handle.close()
                completion.complete()
            }
            // On a pipe, read(upToCount:) can wait to fill the requested count,
            // hiding a quiet emulator's diagnostics until it exits. This queue
            // owns the read handle; availableData returns the next live chunk
            // and blocks only while no bytes are available (or until EOF).
            while true {
                let data = output.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                if written + data.count > limit {
                    try? handle.truncate(atOffset: 0)
                    try? handle.seek(toOffset: 0)
                    written = 0
                }
                try? handle.write(contentsOf: data)
                written += data.count
            }
        }
    }

    func finish() {
        try? output.fileHandleForWriting.close()
    }
}

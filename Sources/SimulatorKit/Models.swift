import Foundation

public struct SDKInstallation: Hashable, Sendable {
    public let root: URL
    public let emulator: URL
    public let adb: URL

    public init(root: URL, emulator: URL, adb: URL) {
        self.root = root
        self.emulator = emulator
        self.adb = adb
    }
}

public struct AVD: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let apiLevel: String
    public let architecture: String
    public let resolution: String
    public let memoryMB: Int
    public let configURL: URL?

    public init(name: String, displayName: String? = nil, apiLevel: String = "Unknown",
                architecture: String = "Unknown", resolution: String = "Unknown",
                memoryMB: Int = 0, configURL: URL? = nil) {
        self.name = name
        self.displayName = displayName ?? name.replacingOccurrences(of: "_", with: " ")
        self.apiLevel = apiLevel
        self.architecture = architecture
        self.resolution = resolution
        self.memoryMB = memoryMB
        self.configURL = configURL
    }
}

public struct ADBDevice: Identifiable, Hashable, Sendable {
    public var id: String { serial }
    public let serial: String
    public let state: String
    public let avdName: String?

    public init(serial: String, state: String, avdName: String? = nil) {
        self.serial = serial
        self.state = state
        self.avdName = avdName
    }
}

public struct CommandResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }

    public init(stdout: Data, stderr: Data, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }

    public func requireSuccess(operation: String) throws {
        guard status == 0 else {
            let details = [stderrText, text].filter { !$0.isEmpty }.joined(separator: "\n")
            throw RuntimeError.commandFailed(operation: operation, status: status,
                                             details: String(details.suffix(6_000)))
        }
    }
}

public enum SessionState: String, CaseIterable, Codable, Sendable {
    case idle, starting, booting, connecting, running, reconnecting, stopping, failed

    public func canTransition(to next: SessionState) -> Bool {
        switch self {
        case .idle: return next == .starting
        case .starting: return [.booting, .failed, .stopping].contains(next)
        case .booting: return [.connecting, .failed, .stopping].contains(next)
        // Connecting can also be cancelled when its device window is stopped.
        case .connecting: return [.running, .reconnecting, .failed, .stopping].contains(next)
        case .running: return [.reconnecting, .stopping, .failed].contains(next)
        case .reconnecting: return [.running, .failed, .stopping].contains(next)
        case .stopping: return [.idle, .failed].contains(next)
        case .failed: return [.starting, .idle].contains(next)
        }
    }
}

public enum RuntimeError: LocalizedError, Sendable {
    case sdkNotFound
    case invalidSDK(path: String, missing: String)
    case invalidArgument(String)
    case commandFailed(operation: String, status: Int32, details: String)
    case commandTimedOut(String, TimeInterval)
    case outputLimitExceeded(String)
    case avdAlreadyRunning(String)
    case architectureMismatch(String)
    case noAvailablePorts
    case emulatorExited(String)

    public var errorDescription: String? {
        switch self {
        case .sdkNotFound:
            return "Android SDK not found. Choose an SDK folder containing emulator/emulator and platform-tools/adb in Settings."
        case let .invalidSDK(path, missing):
            return "The SDK at \(path) is missing an executable \(missing). Install that component using Android Studio’s SDK Manager or choose a different SDK."
        case let .invalidArgument(message): return message
        case let .commandFailed(operation, status, details):
            return "\(operation) failed (exit \(status)). \(details.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .commandTimedOut(command, seconds):
            return "\(command) did not finish within \(Int(seconds)) seconds. Check the device connection and diagnostics, then try again."
        case let .outputLimitExceeded(command):
            return "\(command) produced too much output. Narrow the command or log filter and try again."
        case let .avdAlreadyRunning(name):
            return "\(name) is already running. Stop it in the application that launched it before starting it here."
        case let .architectureMismatch(architecture):
            return "This virtual device uses \(architecture), which is incompatible with this Mac. Create an AVD with a system image for this Mac’s architecture."
        case .noAvailablePorts:
            return "No emulator port pair is available between 5554 and 5683. Stop an unused emulator and try again."
        case let .emulatorExited(details):
            return "The emulator exited during launch. \(details)"
        }
    }
}

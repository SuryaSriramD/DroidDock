import Foundation

/// Transport-independent display/control boundary. A bridge owns its resources
/// for one connection; construct a fresh bridge after stopping or disconnecting.
public protocol DisplayBridge: AnyObject, Sendable {
    func start(onFrame: @escaping @Sendable (DecodedFrame) -> Void,
               onDisconnect: @escaping @Sendable (String) -> Void) async throws
    func stop() async
    func send(_ input: BridgeInput)
    func readClipboard() async throws -> String
}

extension ScrcpyBridge: DisplayBridge { }

/// Features implemented by an adapter, rather than a guess based on the
/// emulator's version number. Connection still validates codec and geometry.
public struct RuntimeCapabilities: Equatable, Sendable {
    public let transportName: String
    public let serverVersion: String
    public let codec: String
    public let supportsTouch: Bool
    public let supportsKeyboard: Bool
    public let supportsScroll: Bool
    public let supportsRotation: Bool
    public let supportsHostToDeviceClipboard: Bool
    public let supportsDeviceToHostClipboard: Bool
    /// A requested ceiling, not a measured frame-rate guarantee.
    public let maximumRequestedFPS: Int
    public let maximumVideoDimension: Int

    public var summary: String {
        "\(transportName), server \(serverVersion), \(codec); requested up to \(maximumRequestedFPS) FPS / \(maximumVideoDimension) px; touch, keyboard, scroll, rotation, bidirectional clipboard on request"
    }
}

/// Actual outputs from the selected SDK tools. Inspection failures are retained
/// as diagnostics; an unavailable version string is never treated as version 0.
public struct RuntimeVersionInfo: Sendable {
    public let emulatorVersion: String
    public let adbVersion: String
    public let hostArchitecture: String
    public let inspectedAt: Date
    public let errors: [String]

    public var summary: String {
        var lines = ["Host architecture: \(hostArchitecture)",
                     "Emulator: \(emulatorVersion)", "ADB version: \(adbVersion)"]
        lines.append(contentsOf: errors.map { "Version inspection: \($0)" })
        return lines.joined(separator: "\n")
    }
}

/// The production candidate implemented in this build. It deliberately does not
/// advertise an emulator-private stream or substitute screenshot polling.
public enum ScrcpyRuntimeAdapter {
    public static let capabilities = RuntimeCapabilities(
        transportName: "scrcpy native bridge", serverVersion: ScrcpyBridge.serverVersion,
        codec: "H.264 / VideoToolbox", supportsTouch: true, supportsKeyboard: true,
        supportsScroll: true, supportsRotation: true,
        supportsHostToDeviceClipboard: true, supportsDeviceToHostClipboard: true,
        maximumRequestedFPS: 60, maximumVideoDimension: 1920
    )

    public static func makeBridge(adb: ADBService, serverURL: URL) -> any DisplayBridge {
        ScrcpyBridge(adb: adb, serverURL: serverURL)
    }

    public static func inspectVersions(sdk: SDKInstallation) async -> RuntimeVersionInfo {
        async let emulator = inspect(executable: sdk.emulator, arguments: ["-version"], label: "Emulator")
        async let adb = inspect(executable: sdk.adb, arguments: ["version"], label: "ADB")
        let results = await (emulator, adb)
        #if arch(arm64)
        let architecture = "arm64 (Apple Silicon)"
        #elseif arch(x86_64)
        let architecture = "x86_64 (Intel)"
        #else
        let architecture = "Unknown"
        #endif
        return RuntimeVersionInfo(emulatorVersion: results.0.version,
                                  adbVersion: results.1.version,
                                  hostArchitecture: architecture, inspectedAt: Date(),
                                  errors: [results.0.error, results.1.error].compactMap { $0 })
    }

    private static func inspect(executable: URL, arguments: [String], label: String) async -> (version: String, error: String?) {
        do {
            let result = try await ProcessRunner.run(executable: executable, arguments: arguments, timeout: 8)
            try result.requireSuccess(operation: "Inspect \(label) version")
            let lines = (result.text + "\n" + result.stderrText).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let versionLines = lines.filter { $0.localizedCaseInsensitiveContains("version") }
            guard !versionLines.isEmpty else {
                return ("Unavailable", "\(label) returned no recognizable version information.")
            }
            return (String(versionLines.joined(separator: "; ").prefix(2_000)), nil)
        } catch {
            return ("Unavailable", "\(label): \(error.localizedDescription)")
        }
    }
}

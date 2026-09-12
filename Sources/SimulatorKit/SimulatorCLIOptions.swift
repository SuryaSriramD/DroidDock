import Foundation

/// Argument parsing is independent of app launch and the filesystem so usage
/// mistakes cannot create devices or start a GUI instance.
public struct SimulatorCLIOptions: Equatable, Sendable {
    public var showHelp = false
    public var showVersion = false
    public var json = false
    public var appPath: String?
    public var timeout: TimeInterval = 120
    public var action: SimulatorCommandAction?
    public var device: String?
    public var argument: String?

    public static func parse(_ arguments: [String]) throws -> Self {
        var result = Self()
        var positional: [String] = []
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let token = arguments[index]
            if !optionsEnded && token == "--" { optionsEnded = true }
            else if !optionsEnded && ["--help", "-h"].contains(token) { result.showHelp = true }
            else if !optionsEnded && token == "--version" { result.showVersion = true }
            else if !optionsEnded && token == "--json" { result.json = true }
            else if !optionsEnded && ["--app", "--timeout"].contains(token) {
                index += 1
                guard index < arguments.count else { throw usage("\(token) requires a value.") }
                if token == "--app" {
                    guard !arguments[index].isEmpty, !arguments[index].contains("\0") else { throw usage("--app requires an app path.") }
                    result.appPath = arguments[index]
                } else {
                    guard let seconds = Double(arguments[index]), seconds.isFinite,
                          (1...SimulatorCommandRequest.maximumTimeout).contains(seconds) else {
                        throw usage("--timeout must be between 1 and 600 seconds.")
                    }
                    result.timeout = seconds
                }
            } else if !optionsEnded && token.hasPrefix("-") { throw usage("Unknown option: \(token)") }
            else { positional.append(token) }
            index += 1
        }
        if arguments.isEmpty { result.showHelp = true }
        if result.showHelp || result.showVersion { return result }
        guard let command = positional.first, let action = SimulatorCommandAction(rawValue: command) else {
            throw usage("Choose a command: list, status, boot, open, stop, install or open-url.")
        }
        result.action = action
        let operands = Array(positional.dropFirst())
        switch action {
        case .list:
            guard operands.isEmpty else { throw usage("Usage: droiddock list [--json]") }
        case .status, .boot, .open:
            guard operands.count <= 1 else { throw usage("Usage: droiddock \(action.rawValue) [device]") }
            result.device = operands.first
        case .stop:
            guard operands.count == 1 else { throw usage("Usage: droiddock stop <device>") }
            result.device = operands[0]
        case .install, .openURL:
            guard operands.count == 2 else { throw usage("Usage: droiddock \(action.rawValue) <device> <\(action == .install ? "apk-path" : "url")>") }
            result.device = operands[0]
            result.argument = operands[1]
        }
        return result
    }

    public func makeRequest(currentDirectory: URL, now: Date = Date()) throws -> SimulatorCommandRequest {
        guard let action else { throw Self.usage("No command was selected.") }
        var resolvedArgument = argument
        if action == .install, let argument {
            resolvedArgument = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath,
                                   relativeTo: currentDirectory).standardizedFileURL.path
        }
        return try SimulatorCommandRequest(action: action, device: device, argument: resolvedArgument,
                                           timeout: timeout, createdAt: now).validated(now: now)
    }

    private static func usage(_ message: String) -> SimulatorCommandError { .invalidRequest(message) }
}

/// Pure discovery ordering allows the preferred brand and compatibility paths
/// to be checked without launching an app or changing the user's environment.
public enum SimulatorCLIAppDiscovery {
    public static func candidates(explicitPath: String?, environment: [String: String],
                                  executableURL: URL?, homeDirectory: URL) -> [URL] {
        if let selected = explicitPath ?? environment["DROIDDOCK_APP"] ?? environment["ANDROID_SIMULATOR_APP"] {
            return [URL(fileURLWithPath: (selected as NSString).expandingTildeInPath).standardizedFileURL]
        }
        var result: [URL] = []
        if let executable = executableURL?.resolvingSymlinksInPath() {
            let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if bundle.pathExtension == "app" { result.append(bundle) }
        }
        for name in ["DroidDock.app", "Android Simulator.app"] {
            result.append(URL(fileURLWithPath: "/Applications/\(name)", isDirectory: true))
            result.append(homeDirectory.appendingPathComponent("Applications/\(name)", isDirectory: true))
        }
        return result
    }
}

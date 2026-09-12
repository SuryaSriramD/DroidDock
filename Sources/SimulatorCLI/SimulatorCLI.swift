import Foundation
import Darwin
import SimulatorKit

@main
enum SimulatorCLI {
    static let version = "droiddock 0.2.1 (local command protocol 1)"
    static let help = """
    DroidDock — control the native Mac app from your terminal.

    Usage: droiddock <command> [options]

      list [--json]                         List available virtual devices
      status [device] [--json]               Show device state and ADB serial
      boot [device] [--timeout seconds]      Start/show a device and wait until ready
      open [device]                         Open the library, or boot a named device
      stop <device>                         Stop a device owned by this app
      install <device> <apk-path>            Install an APK on a running device
      open-url <device> <url>                Open an Expo or application deep link

    Options:
      --json          Print a machine-readable response (all commands)
      --timeout N     Wait up to N seconds; default 120, maximum 600
      --app PATH      Use a specific DroidDock.app bundle
      --help, -h      Show this help without opening the app
      --version       Show the client version without opening the app
      --              End option parsing (for operands beginning with a dash)

    Select a device by its ID or name from list. With no device, boot uses the
    app's selected/default device; status shows all devices. open alone shows
    the library. The native app owns emulator processes; this client never
    launches a separate Android Emulator window.

    App discovery: --app, DROIDDOCK_APP (or legacy ANDROID_SIMULATOR_APP), then
    this client's enclosing app bundle, /Applications, or ~/Applications.
    DroidDock.app is preferred; Android Simulator.app remains a fallback.
    The legacy android-simulator command remains available. No PATH or shell
    files change automatically.

    Expo example (use the same Android SDK as the app):
      droiddock boot Pixel_10_Pro
      npx expo start
      # Press Shift+A and choose Pixel_10_Pro; or use:
      npx expo run:android --device Pixel_10_Pro

    Exit codes: 0 success, 1 app command failed, 2 invalid arguments,
    3 app/transport unavailable, 4 timed out. A timeout does not stop a device
    that has already started; use status to check before retrying.
    """

    static func main() async {
        let options: SimulatorCLIOptions
        let request: SimulatorCommandRequest
        do {
            options = try .parse(Array(CommandLine.arguments.dropFirst()))
            if options.showHelp { output(help + "\n"); return }
            if options.showVersion { output(version + "\n"); return }
            request = try options.makeRequest(currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            if request.action == .install, let path = request.argument {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue,
                      FileManager.default.isReadableFile(atPath: path) else {
                    throw SimulatorCommandError.invalidRequest("The APK file cannot be read: \(path)")
                }
            }
        } catch {
            fail(error.localizedDescription + "\nRun droiddock --help for usage.", code: 2)
        }

        let store = SimulatorCommandStore()
        let exitCode: Int32
        do {
            let app = try locateApp(explicitPath: options.appPath)
            let commandURL = try commandURL(id: request.id, app: app)
            try store.createRequest(request)
            defer { try? store.remove(id: request.id) }
            let started = ProcessInfo.processInfo.systemUptime
            let launch = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-g", "-a", app.path, commandURL.absoluteString],
                timeout: min(15, options.timeout))
            guard launch.status == 0 else {
                throw SimulatorCommandError.unavailable("Could not open \(app.path). \(launch.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            var received: SimulatorCommandResponse?
            while ProcessInfo.processInfo.systemUptime - started < options.timeout {
                if let response = try store.readResponse(id: request.id) { received = response; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let response = received {
                try display(response, json: options.json)
                exitCode = response.success ? 0 : (response.errorCode == "timeout" || response.errorCode == "expired" ? 4 : 1)
            } else {
                let response = SimulatorCommandResponse(id: request.id, success: false,
                    message: "Timed out waiting for DroidDock after \(options.timeout.formatted()) seconds. Check the app for a prompt, then use status to check the device before retrying.", errorCode: "timeout")
                try display(response, json: options.json)
                exitCode = 4
            }
        } catch {
            if options.json {
                try? display(SimulatorCommandResponse(id: request.id, success: false,
                    message: error.localizedDescription, errorCode: "transport_unavailable"), json: true)
            } else { errorOutput(error.localizedDescription + "\n") }
            exitCode = 3
        }
        Darwin.exit(exitCode)
    }

    private static func locateApp(explicitPath: String?) throws -> URL {
        let candidates = SimulatorCLIAppDiscovery.candidates(explicitPath: explicitPath,
            environment: ProcessInfo.processInfo.environment, executableURL: Bundle.main.executableURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        guard let app = candidates.first(where: isApp) else {
            if candidates.count == 1, let selected = candidates.first {
                throw SimulatorCommandError.unavailable("No DroidDock.app or compatible Android Simulator.app bundle was found at \(selected.path).")
            }
            throw SimulatorCommandError.unavailable("DroidDock.app was not found. Move the app to Applications, run its bundled client, or provide --app '/path/DroidDock.app'.")
        }
        return app
    }

    private static func commandURL(id: UUID, app: URL) throws -> URL {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        let types = info?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard let url = SimulatorCommandStore.compatibleCommandURL(id: id, registeredSchemes: schemes) else {
            throw SimulatorCommandError.unavailable("This app version does not support terminal commands. Install the current DroidDock app and try again.")
        }
        return url
    }

    private static func isApp(_ url: URL) -> Bool {
        url.pathExtension == "app" && FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/AndroidSimulator").path)
            && FileManager.default.isReadableFile(atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }

    private static func display(_ response: SimulatorCommandResponse, json: Bool) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            output(String(decoding: try encoder.encode(response), as: UTF8.self) + "\n")
        } else if response.success {
            output(response.message + "\n")
            if !response.devices.isEmpty {
                output("ID\tSTATE\tADB SERIAL\tOWNED\tNAME\n")
                for device in response.devices {
                    output("\(device.id)\t\(device.state)\t\(device.serial ?? "—")\t\(device.isOwned ? "yes" : "no")\t\(device.name)\n")
                }
            }
        } else { errorOutput(response.message + "\n") }
    }

    private static func output(_ text: String) { try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8)) }
    private static func errorOutput(_ text: String) { try? FileHandle.standardError.write(contentsOf: Data(text.utf8)) }
    private static func fail(_ text: String, code: Int32) -> Never { errorOutput(text + "\n"); Darwin.exit(code) }
}

import Foundation
import SimulatorKit
import CoreImage
import CoreVideo
import Darwin

/// Measures native decode throughput. AppKit presentation, resizing, and
/// input-to-visible latency need separate UI checks.
private final class ProbeFrames: @unchecked Sendable {
    struct Snapshot {
        let count: Int
        let last: DecodedFrame?
        let decodeMilliseconds: [Double]
        let dimensions: [String]
        let disconnects: [String]
    }
    private let lock = NSLock()
    private var count = 0
    private var last: DecodedFrame?
    private var decodeMilliseconds: [Double] = []
    private var dimensions: Set<String> = []
    private var disconnects: [String] = []
    func receive(_ frame: DecodedFrame) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        last = frame
        dimensions.insert("\(frame.width)x\(frame.height)")
        decodeMilliseconds.append(max(0, frame.decodedAt - frame.receivedAt) * 1000)
    }
    func disconnected(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        disconnects.append(message)
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(count: count, last: last, decodeMilliseconds: decodeMilliseconds,
                        dimensions: dimensions.sorted(), disconnects: disconnects)
    }
}

private struct ProbeGeometry {
    let values: [String: Int]
    var width: Int { values["width"]! }
    var height: Int { values["height"]! }
    var isPortrait: Bool { height > width }
    init?(_ line: String) {
        var result: [String: Int] = [:]
        for token in line.split(whereSeparator: \.isWhitespace) {
            let pair = token.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Int(pair[1]) { result[String(pair[0])] = value }
        }
        let required = ["width", "height", "buttonX", "buttonY", "textX", "textY", "dragStartX", "dragEndX", "dragY"]
        guard required.allSatisfy({ result[$0] != nil }), result["width"]! > 0, result["height"]! > 0 else { return nil }
        values = result
    }
    func position(_ target: String, frame: DecodedFrame) throws -> (Int, Int) {
        guard let x = values[target + "X"], let y = values[target + "Y"] else { throw ProbeError("Missing geometry for \(target)") }
        return try position(x: x, y: y, frame: frame)
    }
    func position(x: Int, y: Int, frame: DecodedFrame) throws -> (Int, Int) {
        guard (frame.height > frame.width) == isPortrait,
              abs(Double(frame.width) / Double(frame.height) - Double(width) / Double(height)) < 0.01,
              x >= 0, y >= 0, x < width, y < height else { throw ProbeError("Guest target and decoded-frame geometry disagree") }
        return (min(frame.width - 1, x * frame.width / width), min(frame.height - 1, y * frame.height / height))
    }
}

@main
struct SimulatorProbe {
    private static let package = "dev.androidsimulator.probe"
    private static var uptime: Double { ProcessInfo.processInfo.systemUptime }
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("PROBE FAILED: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    private static func run() async throws {
        let sdk = try SDKLocator.resolve(explicitPath: nil)
        let avds = try await AVDRepository.discover(sdk: sdk)
        print("SDK: \(sdk.root.path)")
        for avd in avds { print("AVD: \(avd.name) \(avd.apiLevel) \(avd.architecture)") }
        guard CommandLine.arguments.contains("--run") else { return }
        guard let avd = avds.first else { throw ProbeError("No AVD is installed") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let apk = root.appendingPathComponent("artifacts/test-apk/probe.apk")
        guard FileManager.default.isReadableFile(atPath: apk.path) else {
            throw ProbeError("Build the verification APK first with scripts/build-test-apk.sh")
        }
        let output = root.appendingPathComponent("artifacts/probe")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let server = root.appendingPathComponent("Resources/scrcpy-server")
        let session = UUID().uuidString
        try writeStatus("running", session: session, output: output)
        let manager = EmulatorProcessManager()
        let launchStarted = uptime
        let runtime: RunningEmulator
        do { runtime = try await manager.launch(sdk: sdk, avd: avd, coldBoot: false) }
        catch {
            try? writeStatus("failed", session: session, output: output, error: error.localizedDescription)
            throw error
        }
        print("Headless launch: PID \(runtime.process.processIdentifier), \(runtime.serial), log \(runtime.logURL.path)")
        let adb = ADBService(sdk: sdk, serial: runtime.serial)
        let rotation = GuestRotation(adb: adb)
        let frames = ProbeFrames()
        var bridge: ScrcpyBridge?
        var fixtureOwned = false
        var originalRotationSettings: [String: String]?
        do {
            try await waitUntil("Android boot", timeout: 180) {
                guard runtime.process.isRunning else { throw ProbeError("Emulator exited during boot: \(runtime.logURL.path)") }
                return (try? await adb.shell(["getprop", "sys.boot_completed"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "1"
            }
            let bootSeconds = uptime - launchStarted
            print("Android boot completed in \(formatted(bootSeconds)) seconds")
            guard try await !packageInstalled(adb) else {
                throw ProbeError("The verification package is already installed; refusing to replace or remove a pre-existing installation")
            }
            var rotationSettings: [String: String] = [:]
            for name in ["user_rotation", "accelerometer_rotation"] {
                rotationSettings[name] = try await adb.shell(["settings", "--user", "current", "get", "system", name]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let rotationMode = try await adb.shell(["wm", "user-rotation", "-d", "0"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard rotationMode == "free" || (0...3).contains(where: { rotationMode == "lock \($0)" }) else {
                throw ProbeError("Unsupported wm user-rotation response: \(rotationMode)")
            }
            rotationSettings["windowManagerMode"] = rotationMode
            originalRotationSettings = rotationSettings
            print("Original guest rotation settings: \(rotationSettings)")
            print("Foreground Android user: \(try await adb.shell(["am", "get-current-user"]).trimmingCharacters(in: .whitespacesAndNewlines)); rotation: \(rotationMode)")
            fixtureOwned = true
            try await adb.install(apk: apk)
            _ = try await adb.shell(["am", "start", "-W", "-n", package + "/.ProbeActivity", "--es", "session", session])
            _ = try await waitForLog("CREATED", adb: adb, session: session)
            print("Verification APK installed and started")
            let initialForwards = try await forwards(adb)
            let initial = ScrcpyBridge(adb: adb, serverURL: server)
            bridge = initial
            try await initial.start(onFrame: { frames.receive($0) }, onDisconnect: { frames.disconnected($0) })
            try await waitUntil("first decoded frame") { frames.snapshot().last != nil }
            print("Native bridge connected")
            var geometry = try await orient(portrait: true, rotation: rotation, frames: frames, adb: adb, session: session)
            try await waitUntil("settled animated fixture") { frames.snapshot().count >= 30 }
            try saveFrame(frames, to: output.appendingPathComponent("before-input.png"))
            try await tap("button", geometry: geometry, bridge: initial, frames: frames)
            _ = try await waitForLog("TOUCH_VERIFIED touches=1", adb: adb, session: session)
            try await tap("text", geometry: geometry, bridge: initial, frames: frames)
            let expectedText = "Native bridge 123"
            initial.send(.text(expectedText))
            _ = try await waitForLog("TEXT=" + expectedText, adb: adb, session: session)
            key(4, bridge: initial)
            try await Task.sleep(nanoseconds: 700_000_000)
            geometry = try await currentGeometry(adb: adb, session: session, portrait: true)
            try await drag(geometry: geometry, bridge: initial, frames: frames)
            _ = try await waitForLog("DRAG_VERIFIED drags=1", adb: adb, session: session)
            print("Direct scrcpy tap, keyboard text, and continuous drag verified by guest events")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let benchmarkStart = uptime
            let benchmarkBefore = frames.snapshot()
            var previousTime = benchmarkStart
            var previousCount = benchmarkBefore.count
            var windows: [[String: Any]] = []
            for index in 0..<6 {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                let now = uptime
                let snapshot = frames.snapshot()
                guard snapshot.disconnects.isEmpty else { throw ProbeError("Unexpected bridge disconnect: \(snapshot.disconnects)") }
                let fps = Double(snapshot.count - previousCount) / (now - previousTime)
                windows.append(["seconds": now - previousTime, "frames": snapshot.count - previousCount, "decodedFPS": fps])
                print("Animated workload \((index + 1) * 10)/60s: \(formatted(fps)) decoded FPS")
                previousTime = now
                previousCount = snapshot.count
            }
            let benchmarkSeconds = previousTime - benchmarkStart
            let benchmarkFrames = previousCount - benchmarkBefore.count
            let fps = Double(benchmarkFrames) / benchmarkSeconds
            let minimumWindowFPS = windows.compactMap { $0["decodedFPS"] as? Double }.min() ?? 0
            let throughputPassed = fps >= 30 && minimumWindowFPS >= 30
            if !throughputPassed { print("Throughput below target; collecting the remaining functional evidence before reporting failure") }
            try saveFrame(frames, to: output.appendingPathComponent("decoded-portrait.png"))
            let portraitFrame = frames.snapshot().last!
            geometry = try await orient(portrait: false, rotation: rotation, frames: frames, adb: adb, session: session)
            let landscapeFrame = frames.snapshot().last!
            guard portraitFrame.width == landscapeFrame.height, portraitFrame.height == landscapeFrame.width else {
                throw ProbeError("Rotation did not exchange decoded dimensions")
            }
            try await tap("button", geometry: geometry, bridge: initial, frames: frames)
            _ = try await waitForLog("TOUCH_VERIFIED touches=2 text=" + expectedText, adb: adb, session: session)
            try await Task.sleep(nanoseconds: 200_000_000)
            try saveFrame(frames, to: output.appendingPathComponent("decoded-landscape.png"))
            geometry = try await orient(portrait: true, rotation: rotation, frames: frames, adb: adb, session: session)
            print("Portrait \(portraitFrame.width)x\(portraitFrame.height), landscape \(landscapeFrame.width)x\(landscapeFrame.height), and landscape hit target verified")
            // A static display sends no video; it must survive the old 20s timeout.
            key(131, bridge: initial)
            _ = try await waitForLog("ANIMATION_PAUSED", adb: adb, session: session)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let idleBefore = frames.snapshot().count
            let idleStart = uptime
            try await Task.sleep(nanoseconds: 23_000_000_000)
            let idleSeconds = uptime - idleStart
            let idle = frames.snapshot()
            guard idle.disconnects.isEmpty, idle.count - idleBefore <= 1 else {
                throw ProbeError("Static-stream test did not remain idle and connected: \(idle.count - idleBefore) frames, \(idle.disconnects)")
            }
            key(131, bridge: initial)
            _ = try await waitForLog("ANIMATION_RESUMED", adb: adb, session: session)
            try await waitUntil("frames after static screen") { frames.snapshot().count > idle.count }
            print("Static display remained connected for \(formatted(idleSeconds))s with \(idle.count - idleBefore) new frames; animation resumed")
            let screenshot = output.appendingPathComponent("android-screenshot.png")
            try await adb.screenshot(to: screenshot)
            guard let screenshotImage = CIImage(contentsOf: screenshot),
                  screenshotImage.extent.width == CGFloat(geometry.width),
                  screenshotImage.extent.height == CGFloat(geometry.height) else { throw ProbeError("Captured PNG dimensions do not match Android's display") }
            let pid = runtime.process.processIdentifier
            await initial.stop()
            let reconnectBefore = frames.snapshot().count
            let next = ScrcpyBridge(adb: adb, serverURL: server)
            bridge = next
            try await next.start(onFrame: { frames.receive($0) }, onDisconnect: { frames.disconnected($0) })
            try await waitUntil("reconnected frames") { frames.snapshot().count > reconnectBefore }
            guard runtime.process.isRunning, runtime.process.processIdentifier == pid else { throw ProbeError("Bridge reconnect replaced or stopped the emulator") }
            geometry = try await currentGeometry(adb: adb, session: session, portrait: true)
            try await tap("button", geometry: geometry, bridge: next, frames: frames)
            _ = try await waitForLog("TOUCH_VERIFIED touches=3 text=" + expectedText, adb: adb, session: session)
            let final = frames.snapshot()
            guard final.disconnects.isEmpty else { throw ProbeError("Unexpected bridge disconnect: \(final.disconnects)") }
            print("Bridge reconnected with original PID \(pid), recovered control, and preserved guest text/counter state")
            let guestLog = try await log(adb: adb, session: session)
            try guestLog.write(to: output.appendingPathComponent("guest-events.log"), atomically: true, encoding: .utf8)
            try (initial.diagnosticLog + "\n--- Reconnected bridge ---\n" + next.diagnosticLog)
                .write(to: output.appendingPathComponent("bridge-events.log"), atomically: true, encoding: .utf8)
            await next.stop()
            guard try await forwards(adb) == initialForwards else { throw ProbeError("Probe changed the pre-existing ADB forward set after cleanup") }
            await rotation.restore()
            try await verifyRotationRestored(rotationSettings, adb: adb)
            originalRotationSettings = nil
            _ = try await adb.run(["uninstall", package], timeout: 60)
            guard try await !packageInstalled(adb) else { throw ProbeError("Verification APK remains installed after uninstall") }
            fixtureOwned = false
            let androidAPI = try await adb.shell(["getprop", "ro.build.version.sdk"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let androidABI = try await adb.shell(["getprop", "ro.product.cpu.abi"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let emulatorVersion = try await ProcessRunner.run(executable: sdk.emulator, arguments: ["-version"], timeout: 10).text
            let adbVersion = try await adb.run(["version"]).text
            let hostModel = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/sbin/sysctl"), arguments: ["-n", "hw.model"], timeout: 10).text.trimmingCharacters(in: .whitespacesAndNewlines)
            #if arch(arm64)
            let hostArchitecture = "arm64"
            #elseif arch(x86_64)
            let hostArchitecture = "x86_64"
            #else
            let hostArchitecture = "other"
            #endif
            await manager.stop(runtime)
            try await waitUntil("owned emulator exit", timeout: 5) { !runtime.process.isRunning }
            let emulatorLog = (try? String(contentsOf: runtime.logURL, encoding: .utf8)) ?? ""
            let graphicsDetails = emulatorLog.split(whereSeparator: \.isNewline)
                .filter { $0.contains("emuglConfig_init") || $0.contains("Graphics Adapter") || $0.contains("Selecting Vulkan device") }.map(String.init)
            let delays = final.decodeMilliseconds.sorted()
            let metrics: [String: Any] = [
                "avd": avd.name, "serial": runtime.serial, "runtimePID": pid, "headless": true,
                "bootSeconds": bootSeconds, "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "hostArchitecture": hostArchitecture, "hostModel": hostModel, "androidAPI": androidAPI, "androidABI": androidABI,
                "emulatorVersion": emulatorVersion, "adbVersion": adbVersion, "scrcpyServerVersion": ScrcpyBridge.serverVersion,
                "emulatorArguments": runtime.process.arguments ?? [], "emulatorGraphics": graphicsDetails, "emulatorLog": runtime.logURL.path,
                "measurementScope": "H.264 frames decoded by VideoToolbox; excludes AppKit presentation and input-to-visible latency",
                "workload": "Continuously animated on-device verification APK; six uninterrupted ten-second sample windows",
                "benchmarkSeconds": benchmarkSeconds, "benchmarkFrames": benchmarkFrames, "activeFPS": fps,
                "minimumTenSecondFPS": minimumWindowFPS, "benchmarkWindows": windows,
                "throughputPassed": throughputPassed,
                "totalDecodedFrames": final.count, "averageReceiveToDecodeMs": delays.reduce(0, +) / Double(delays.count),
                "p95ReceiveToDecodeMs": delays[min(delays.count - 1, Int(Double(delays.count) * 0.95))],
                "decodedDimensions": final.dimensions, "bothOrientationsVerified": true,
                "rotationTestCondition": "Display rotation locked with selected-serial ADB wm user-rotation; original guest settings and free/lock mode restored",
                "rotationImplementation": "SimulatorKit.GuestRotation",
                "originalRotationSettings": rotationSettings, "rotationSettingsRestored": true,
                "directControlTouchVerified": true, "directControlTextVerified": true, "directControlDragVerified": true,
                "idleStreamSeconds": idleSeconds, "idleStreamFrames": idle.count - idleBefore, "idleStreamRecovered": true,
                "bridgeReconnected": true, "runtimePIDPreserved": true, "guestStatePreserved": true,
                "screenshotCaptured": true, "screenshotWidth": geometry.width, "screenshotHeight": geometry.height,
                "fixtureUninstalled": true, "adbForwardsRestored": true, "ownedEmulatorStopped": true,
                "measuredAt": Date().formatted(.iso8601), "session": session
            ]
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("metrics.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
            guard throughputPassed else { throw ProbeError("Sustained decode throughput below 30 FPS: average \(formatted(fps)), minimum ten-second window \(formatted(minimumWindowFPS)); all functional checks passed and owned resources were cleaned up") }
            try writeStatus("passed", session: session, output: output)
            print("PROBE PASSED; verification APK uninstalled and owned emulator stopped")
        } catch {
            try? writeStatus("failed", session: session, output: output, error: error.localizedDescription)
            try? bridge?.diagnosticLog.write(to: output.appendingPathComponent("bridge-failure.log"), atomically: true, encoding: .utf8)
            try? saveFrame(frames, to: output.appendingPathComponent("decoded-failure.png"))
            try? await adb.screenshot(to: output.appendingPathComponent("android-failure.png"))
            if let guestLog = try? await log(adb: adb, session: session) {
                try? guestLog.write(to: output.appendingPathComponent("guest-events-failure.log"), atomically: true, encoding: .utf8)
            }
            await bridge?.stop()
            await rotation.restore()
            if let settings = originalRotationSettings { try? await verifyRotationRestored(settings, adb: adb) }
            if fixtureOwned { _ = try? await adb.run(["uninstall", package], timeout: 60) }
            await manager.stop(runtime)
            throw error
        }
    }
    private static func waitUntil(_ description: String, timeout: Double = 15, condition: () async throws -> Bool) async throws {
        let deadline = uptime + timeout
        while uptime < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ProbeError("Timed out waiting for \(description)")
    }
    private static func log(adb: ADBService, session: String) async throws -> String {
        try await adb.run(["logcat", "-d", "-v", "brief", "-s", "SimulatorProbe:I", "*:S"]).text
            .split(whereSeparator: \.isNewline).filter { $0.contains("SESSION=" + session + " ") }.joined(separator: "\n")
    }
    @discardableResult
    private static func waitForLog(_ marker: String, adb: ADBService, session: String) async throws -> String {
        var result = ""
        try await waitUntil("guest event \(marker)") {
            result = try await log(adb: adb, session: session)
            return result.contains("SESSION=" + session + " " + marker)
        }
        return result
    }
    private static func currentGeometry(adb: ADBService, session: String, portrait: Bool) async throws -> ProbeGeometry {
        var geometry: ProbeGeometry?
        try await waitUntil("\(portrait ? "portrait" : "landscape") guest geometry") {
            let events = try await log(adb: adb, session: session)
            geometry = events.split(whereSeparator: \.isNewline).filter { $0.contains(" GEOMETRY ") }
                .compactMap { ProbeGeometry(String($0)) }.last
            return geometry?.isPortrait == portrait
        }
        return geometry!
    }
    private static func orient(portrait: Bool, rotation: GuestRotation, frames: ProbeFrames, adb: ADBService, session: String) async throws -> ProbeGeometry {
        guard let current = frames.snapshot().last else { throw ProbeError("No frame for orientation check") }
        if (current.height > current.width) != portrait {
            try await rotation.rotate(to: portrait ? 0 : 1)
        }
        try await waitUntil("\(portrait ? "portrait" : "landscape") decoded dimensions") {
            guard let frame = frames.snapshot().last else { return false }
            return (frame.height > frame.width) == portrait
        }
        let geometry = try await currentGeometry(adb: adb, session: session, portrait: portrait)
        try await Task.sleep(nanoseconds: 700_000_000)
        return geometry
    }
    private static func tap(_ target: String, geometry: ProbeGeometry, bridge: ScrcpyBridge, frames: ProbeFrames) async throws {
        guard let frame = frames.snapshot().last else { throw ProbeError("No frame for tap") }
        let (x, y) = try geometry.position(target, frame: frame)
        bridge.send(.touch(action: 0, x: x, y: y, width: frame.width, height: frame.height))
        try await Task.sleep(nanoseconds: 50_000_000)
        bridge.send(.touch(action: 1, x: x, y: y, width: frame.width, height: frame.height))
    }
    private static func drag(geometry: ProbeGeometry, bridge: ScrcpyBridge, frames: ProbeFrames) async throws {
        guard let frame = frames.snapshot().last else { throw ProbeError("No frame for drag") }
        let (start, y) = try geometry.position(x: geometry.values["dragStartX"]!, y: geometry.values["dragY"]!, frame: frame)
        let (end, _) = try geometry.position(x: geometry.values["dragEndX"]!, y: geometry.values["dragY"]!, frame: frame)
        bridge.send(.touch(action: 0, x: start, y: y, width: frame.width, height: frame.height))
        for step in 1...30 {
            try await Task.sleep(nanoseconds: 16_000_000)
            bridge.send(.touch(action: 2, x: start + (end - start) * step / 30, y: y, width: frame.width, height: frame.height))
        }
        bridge.send(.touch(action: 1, x: end, y: y, width: frame.width, height: frame.height))
    }
    private static func key(_ code: UInt32, bridge: ScrcpyBridge) {
        bridge.send(.key(code: code, down: true))
        bridge.send(.key(code: code, down: false))
    }
    private static func forwards(_ adb: ADBService) async throws -> Set<String> {
        Set(try await adb.run(["forward", "--list"]).text.split(whereSeparator: \.isNewline)
            .filter { $0.split(whereSeparator: \.isWhitespace).first == Substring(adb.serial) }.map(String.init))
    }
    private static func packageInstalled(_ adb: ADBService) async throws -> Bool {
        try await adb.shell(["pm", "list", "packages", package]).split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "package:" + package }
    }
    private static func verifyRotationRestored(_ settings: [String: String], adb: ADBService) async throws {
        for name in ["user_rotation", "accelerometer_rotation"] {
            guard let value = settings[name] else { continue }
            let restored = try await adb.shell(["settings", "--user", "current", "get", "system", name]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard restored == value else { throw ProbeError("Could not restore original Android \(name) setting") }
        }
        if let mode = settings["windowManagerMode"] {
            try await waitUntil("restored window-manager rotation") {
                try await adb.shell(["wm", "user-rotation", "-d", "0"]).trimmingCharacters(in: .whitespacesAndNewlines) == mode
            }
        }
    }
    private static func saveFrame(_ frames: ProbeFrames, to url: URL) throws {
        guard let frame = frames.snapshot().last else { throw ProbeError("No frame to capture") }
        try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: frame.pixelBuffer), to: url,
                                              format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    private static func formatted(_ value: Double) -> String { String(format: "%.2f", value) }
    private static func writeStatus(_ state: String, session: String, output: URL, error: String? = nil) throws {
        var status: [String: Any] = ["state": state, "session": session, "updatedAt": Date().formatted(.iso8601)]
        if let error { status["error"] = error }
        try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("run-status.json"), options: .atomic)
    }
}

private struct ProbeError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

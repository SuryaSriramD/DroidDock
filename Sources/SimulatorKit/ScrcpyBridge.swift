import Foundation
import CryptoKit
import Darwin

public enum ScrcpyError: LocalizedError {
    case server(String)
    case protocolViolation(String)
    case decode(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .server(let message), .protocolViolation(let message), .decode(let message), .transport(let message): return message
        }
    }
}

/// Native display/control client. It never launches the scrcpy desktop UI.
/// A bridge is single-use: reconnect by stopping it and constructing a new one.
public final class ScrcpyBridge: @unchecked Sendable {
    public static let serverVersion = "3.3.3"
    public static let serverSHA256 = "7e70323ba7f259649dd4acce97ac4fefbae8102b2c6d91e2e7be613fd5354be0"

    private let adb: ADBService
    private let serverURL: URL
    private let scid = UInt32.random(in: 1...0x7fff_ffff)
    private let lock = NSLock()
    private let videoQueue = DispatchQueue(label: "simulator.video", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "simulator.input", qos: .userInteractive)
    private let deviceMessageQueue = DispatchQueue(label: "simulator.device-messages", qos: .utility)
    private var hasStarted = false
    private var stopped = false
    private var connected = false
    private var disconnectReported = false
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var videoSocket: BridgeSocket?
    private var controlSocket: BridgeSocket?
    private var port: Int?
    private var serverLog = Data()
    private var onDisconnect: (@Sendable (String) -> Void)?
    private var pendingInput: [(BridgeInput, Data)] = []
    private var pendingInputBytes = 0
    private var sendingInput = false
    private let clipboardReplies = ClipboardReplyChannel()

    private var remotePath: String { "/data/local/tmp/android-simulator-\(String(format: "%08x", scid)).jar" }

    public init(adb: ADBService, serverURL: URL) {
        self.adb = adb
        self.serverURL = serverURL
    }

    /// Bounded server output for actionable diagnostics, including input failures.
    public var diagnosticLog: String {
        lock.withLock { String(decoding: serverLog, as: UTF8.self) }
    }

    public func start(onFrame: @escaping @Sendable (DecodedFrame) -> Void,
                      onDisconnect: @escaping @Sendable (String) -> Void) async throws {
        try lock.withLock {
            guard !hasStarted && !stopped else { throw ScrcpyError.server("Create a new display bridge to reconnect.") }
            hasStarted = true
            self.onDisconnect = onDisconnect
        }
        try await withTaskCancellationHandler {
            do {
                let jar = try Data(contentsOf: serverURL, options: .mappedIfSafe)
                let digest = SHA256.hash(data: jar).map { String(format: "%02x", $0) }.joined()
                guard digest == Self.serverSHA256 else {
                    throw ScrcpyError.server("The bundled display server failed its SHA-256 integrity check. Rebuild or reinstall DroidDock.")
                }
                try checkActive()
                _ = try await adb.run(["push", serverURL.path, remotePath], timeout: 30)
                try checkActive()
                let forwarded = try await adb.run(["forward", "tcp:0", "localabstract:scrcpy_\(String(format: "%08x", scid))"])
                guard let allocatedPort = Int(forwarded.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      allocatedPort > 0 && allocatedPort <= 65535 else {
                    throw ScrcpyError.transport("ADB did not allocate a display port: \(forwarded.text)")
                }
                lock.withLock { port = allocatedPort }
                try checkActive()
                try launchServer()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    videoQueue.async { [self] in
                        do {
                            let (video, control) = try connect(port: allocatedPort)
                            lock.withLock { connected = true }
                            deviceMessageQueue.async { [self] in drainDeviceMessages(control) }
                            continuation.resume()
                            receiveVideo(video, onFrame: onFrame)
                        } catch {
                            continuation.resume(throwing: contextualError(error))
                        }
                    }
                }
                try checkActive()
            } catch {
                await stop()
                throw error
            }
        } onCancel: {
            self.cancelLocalResources()
        }
    }

    public func stop() async {
        cancelLocalResources()
        let cleanup = lock.withLock { () -> (Int?, Process?) in
            let values = (port, process)
            port = nil
            process = nil
            return values
        }
        // All operations target this session's exact forward and unique jar.
        // No global adb kill-server or Android app-process termination is used.
        let adb = self.adb
        let path = remotePath
        // stop is also called from a cancelled start task. Cleanup commands must
        // not inherit cancellation and abandon a forward after taking ownership.
        await Task.detached(priority: .utility) {
            if let port = cleanup.0 { _ = try? await adb.run(["forward", "--remove", "tcp:\(port)"], timeout: 3) }
            _ = try? await adb.run(ADBService.shellArguments(for: ["rm", "-f", path]), timeout: 3)
            if let child = cleanup.1, child.isRunning {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }.value
    }

    public func send(_ input: BridgeInput) {
        let bytes = ScrcpyControlEncoder.encode(input)
        let result = lock.withLock { () -> (schedule: Bool, overflow: Bool) in
            guard connected && !stopped else { return (false, false) }
            if input.isMove, let last = pendingInput.last, last.0.isMove {
                pendingInputBytes -= last.1.count
                pendingInput[pendingInput.count - 1] = (input, bytes)
                pendingInputBytes += bytes.count
                return (false, false)
            }
            guard pendingInput.count < 128, pendingInputBytes + bytes.count <= 1_048_576 else { return (false, true) }
            pendingInput.append((input, bytes))
            pendingInputBytes += bytes.count
            if sendingInput { return (false, false) }
            sendingInput = true
            return (true, false)
        }
        if result.overflow { signalDisconnect(ScrcpyError.transport("The Android input channel stopped responding. Reconnect the display.")) }
        if result.schedule { controlQueue.async { [self] in flushInput() } }
    }

    public func readClipboard() async throws -> String {
        guard lock.withLock({ connected && !stopped }) else { throw ScrcpyError.transport("The Android display is disconnected.") }
        return try await clipboardReplies.request { [weak self] in self?.send(.getClipboard) }
    }

    private func launchServer() throws {
        let child = Process()
        child.executableURL = adb.sdk.adb
        // Every dynamic field is generated locally from a random integer. No
        // user-provided shell string is concatenated into this remote command.
        child.arguments = ["-s", adb.serial, "shell", "CLASSPATH=\(remotePath)", "app_process", "/",
            "com.genymobile.scrcpy.Server", Self.serverVersion, "scid=\(String(format: "%08x", scid))",
            "log_level=info", "audio=false", "video=true", "control=true", "video_codec=h264",
            "max_size=1920", "max_fps=60", "video_bit_rate=8000000", "tunnel_forward=true",
            "send_device_meta=false", "send_codec_meta=true", "send_frame_meta=true",
            "send_dummy_byte=true", "clipboard_autosync=false", "cleanup=true"]
        let output = Pipe()
        let errors = Pipe()
        child.standardOutput = output
        child.standardError = errors
        for pipe in [output, errors] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                self?.appendLog(data)
            }
        }
        child.terminationHandler = { [weak self] child in
            self?.signalDisconnect(ScrcpyError.server("Android display server exited (\(child.terminationStatus))."))
        }
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            process = child
            stdoutPipe = output
            stderrPipe = errors
            try child.run()
        }
    }

    private func connect(port: Int) throws -> (BridgeSocket, BridgeSocket) {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var video: BridgeSocket?
        var lastError: Error = ScrcpyError.transport("Android display server was not ready.")
        while ProcessInfo.processInfo.systemUptime < deadline {
            try checkActive()
            if let child = lock.withLock({ process }), !child.isRunning {
                throw ScrcpyError.server("Android display server exited before connecting.")
            }
            do {
                let candidate = try BridgeSocket(port: port, readTimeout: 1)
                try register(candidate, isControl: false)
                let dummy = try candidate.readExactly(1)
                guard dummy.first == 0 else { throw ScrcpyError.protocolViolation("Invalid display handshake.") }
                video = candidate
                break
            } catch {
                lastError = error
                lock.withLock { videoSocket?.shutdown(); videoSocket = nil }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        guard let video else { throw ScrcpyError.transport("Timed out connecting the Android display. \(lastError.localizedDescription)") }
        // Server accepts video then control; codec header is sent after both.
        let control = try BridgeSocket(port: port, readTimeout: 0)
        try register(control, isControl: true)
        video.setReadTimeout(20)
        let codec: UInt32 = try video.readExactly(4).integerBE(at: 0)
        guard codec == 0x68323634 else { throw ScrcpyError.protocolViolation("Android did not provide an H.264 video stream (codec \(codec)).") }
        let size = try video.readExactly(8)
        let width: UInt32 = size.integerBE(at: 0)
        let height: UInt32 = size.integerBE(at: 4)
        guard width > 0 && height > 0 && width <= 8192 && height <= 8192 else {
            throw ScrcpyError.protocolViolation("Invalid Android video dimensions: \(width) × \(height).")
        }
        // scrcpy produces video only when Android's display changes. A static
        // screen may stay quiet indefinitely; socket shutdown still interrupts
        // reads immediately on stop/reconnect. Bound only the initial handshake.
        video.setReadTimeout(0)
        return (video, control)
    }

    private func receiveVideo(_ socket: BridgeSocket, onFrame: @escaping @Sendable (DecodedFrame) -> Void) {
        let decoder = VideoDecoder(onFrame: onFrame)
        defer { decoder.invalidate() }
        do {
            while !lock.withLock({ stopped }) {
                try autoreleasepool {
                    let header = try ScrcpyPacketHeader(data: socket.readExactly(12))
                    let packet = try socket.readExactly(header.size)
                    try decoder.decode(packet, header: header, receivedAt: ProcessInfo.processInfo.systemUptime)
                }
            }
        } catch { signalDisconnect(error) }
    }

    private func flushInput() {
        while true {
            let item = lock.withLock { () -> (Data, BridgeSocket)? in
                guard !stopped, let socket = controlSocket, !pendingInput.isEmpty else {
                    sendingInput = false
                    return nil
                }
                let data = pendingInput.removeFirst().1
                pendingInputBytes -= data.count
                return (data, socket)
            }
            guard let (data, socket) = item else { return }
            do { try socket.writeAll(data) }
            catch { signalDisconnect(error); return }
        }
    }

    private func drainDeviceMessages(_ socket: BridgeSocket) {
        // Clipboard requests and other replies use their own receive queue.
        // Autosync is disabled: only an explicit request can change Mac content.
        do {
            while !lock.withLock({ stopped }) {
                let type = try socket.readExactly(1)[0]
                switch type {
                case 0:
                    let count: UInt32 = try socket.readExactly(4).integerBE(at: 0)
                    guard count <= 1 << 18 else { throw ScrcpyError.protocolViolation("Oversized Android clipboard message.") }
                    let bytes = try socket.readExactly(Int(count))
                    guard let text = String(data: bytes, encoding: .utf8) else { throw ScrcpyError.protocolViolation("Android clipboard contained invalid UTF-8.") }
                    clipboardReplies.receive(text)
                case 1: _ = try socket.readExactly(8) // Clipboard sequence acknowledgement.
                case 2:
                    let header = try socket.readExactly(4) // UHID id + payload size.
                    let count: UInt16 = header.integerBE(at: 2)
                    _ = try socket.readExactly(Int(count))
                default: throw ScrcpyError.protocolViolation("Unknown Android control message: \(type).")
                }
            }
        } catch { signalDisconnect(error) }
    }

    private func register(_ socket: BridgeSocket, isControl: Bool) throws {
        try lock.withLock {
            guard !stopped else { socket.shutdown(); throw CancellationError() }
            if isControl { controlSocket = socket } else { videoSocket = socket }
        }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if lock.withLock({ stopped }) { throw CancellationError() }
    }

    private func appendLog(_ data: Data) {
        lock.withLock {
            serverLog.append(data)
            if serverLog.count > 32768 { serverLog = Data(serverLog.suffix(32768)) }
        }
    }

    private func contextualError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let log = lock.withLock { String(decoding: serverLog, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return ScrcpyError.transport(error.localizedDescription + (log.isEmpty ? "" : "\n\(log)"))
    }

    private func signalDisconnect(_ error: Error) {
        let callback = lock.withLock { () -> (@Sendable (String) -> Void)? in
            guard connected && !stopped && !disconnectReported else { return nil }
            disconnectReported = true
            return onDisconnect
        }
        guard let callback else { return }
        let message = contextualError(error).localizedDescription
        cancelLocalResources()
        callback(message)
    }

    private func cancelLocalResources() {
        clipboardReplies.close()
        let resources = lock.withLock { () -> (BridgeSocket?, BridgeSocket?, Process?) in
            stopped = true
            connected = false
            pendingInput.removeAll()
            pendingInputBytes = 0
            let resources = (videoSocket, controlSocket, process)
            videoSocket = nil
            controlSocket = nil
            return resources
        }
        resources.0?.shutdown()
        resources.1?.shutdown()
        if let process = resources.2, process.isRunning { process.terminate() }
    }
}

/// A socket descriptor is closed only when its object dies. shutdown() unblocks
/// current reads/writes but cannot race with descriptor reuse on another thread.
private final class BridgeSocket: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var isShutdown = false

    init(port: Int, readTimeout: Int) throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw ScrcpyError.transport("Could not allocate a display socket.") }
        var noSignal: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var noDelay: Int32 = 1
        setsockopt(socketDescriptor, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        var receiveBuffer: Int32 = 131072
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var writeTimeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(socketDescriptor)
            throw ScrcpyError.transport("Could not connect to ADB display port: \(message)")
        }
        descriptor = socketDescriptor
        setReadTimeout(readTimeout)
    }

    deinit { Darwin.close(descriptor) }

    func shutdown() {
        lock.withLock {
            if !isShutdown { isShutdown = true; Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }

    func setReadTimeout(_ seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0 && count <= ScrcpyPacketHeader.maximumPacketSize else { throw ScrcpyError.protocolViolation("Invalid socket read size.") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let received = Darwin.recv(descriptor, raw.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else {
                    throw ScrcpyError.transport(received == 0 ? "Android display connection closed." : "Android display read failed: \(String(cString: strerror(errno)))")
                }
                offset += received
            }
        }
        return data
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ScrcpyError.transport("Android input write failed: \(String(cString: strerror(errno)))") }
                offset += written
            }
        }
    }
}

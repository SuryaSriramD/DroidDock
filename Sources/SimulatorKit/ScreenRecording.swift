import Foundation
import AVFoundation
import CoreVideo
import Darwin

/// One selected-device recording. Android's screenrecord records video only;
/// keep guest orientation fixed until finalization. A recorder is single-use.
public actor ScreenRecording {
    public struct Result: Sendable {
        public let url: URL
        public let byteCount: Int64
        public let duration: TimeInterval
        public let width: Int
        public let height: Int
        public let cleanupWarning: String?
    }

    public static let maximumFileBytes: Int64 = 256 * 1_024 * 1_024
    private let adb: ADBService
    private let identifier = UUID().uuidString.lowercased()
    private var completion: Task<Result, Error>?
    private var terminal: Swift.Result<Result, Error>?
    private var remoteTask: Task<CommandResult, Error>?
    private var remoteOutcome: Swift.Result<CommandResult, Error>?
    private var remoteExitConfirmed = true
    private var identity: RecordingProcessIdentity?
    private var bootID: String?
    private var directoryOwned = false
    private var started = false
    private var stopRequested = false
    private var discardRequested = false
    private var cleanupSucceeded = true
    private var localDirectory: URL?

    private var remoteDirectory: String { "/data/local/tmp/android-simulator-recording-" + identifier }
    private var remoteFile: String { remoteDirectory + "/capture.mp4" }
    private var remotePIDFile: String { remoteDirectory + "/pid" }

    public init(adb: ADBService) { self.adb = adb }

    /// Destination selection precedes recording. Pass overwriteExisting only
    /// after the save panel has explicitly approved replacing that file.
    public func start(to destination: URL, maximumDuration: Int = 180, overwriteExisting: Bool = false) async throws {
        guard completion == nil, !stopRequested else { throw RecordingError("This recorder has already been started or stopped.") }
        guard (1...180).contains(maximumDuration) else { throw RecordingError("Recording duration must be between 1 and 180 seconds.") }
        try Self.validateDestination(destination, overwriteExisting: overwriteExisting)
        let expectedDestination = try RecordingDestinationIdentity.read(at: destination)
        completion = Task {
            do {
                let result = try await perform(destination: destination, maximumDuration: maximumDuration, overwriteExisting: overwriteExisting, expectedDestination: expectedDestination)
                terminal = .success(result)
                return result
            } catch {
                terminal = .failure(error)
                throw error
            }
        }
        do {
            try await withTaskCancellationHandler {
                while !started {
                    if let terminal { _ = try terminal.get(); return }
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            } onCancel: {
                Task { await self.cancel() }
            }
        } catch {
            await cancel()
            throw error
        }
    }

    /// SIGINT finalizes Android's MP4 before pulling it. This also joins a start
    /// already in flight. Repeated finish/observer calls share the same result.
    public func finish() async throws -> Result {
        guard let completion else { throw RecordingError("No screen recording has been started.") }
        stopRequested = true
        return try await completion.value
    }

    /// Completes automatically when Android reaches its bounded time limit.
    public func waitForCompletion() async throws -> Result {
        guard let completion else { throw RecordingError("No screen recording has been started.") }
        return try await completion.value
    }

    /// Discard an unfinished recording and await exact-process/file cleanup.
    /// A recording already exported successfully is never deleted by cancel.
    @discardableResult
    public func cancel() async -> Bool {
        discardRequested = true; stopRequested = true
        if let completion { _ = await completion.result }
        return cleanupSucceeded
    }

    private func perform(destination: URL, maximumDuration: Int, overwriteExisting: Bool, expectedDestination: RecordingDestinationIdentity) async throws -> Result {
        do {
            let initialBoot = try await shell(["cat", "/proc/sys/kernel/random/boot_id"])
            guard UUID(uuidString: initialBoot) != nil else { throw RecordingError("Android did not provide a valid runtime identity.") }
            bootID = initialBoot
            if discardRequested { throw CancellationError() }
            _ = try await shell(["mkdir", "-m", "700", remoteDirectory])
            directoryOwned = true
            if discardRequested { throw CancellationError() }
            // The shell writes its exact PID, then exec preserves that PID.
            // Every interpolated value below is locally generated and bounded.
            let script = "umask 077; echo $$ > '\(remotePIDFile)'; exec /system/bin/screenrecord --verbose --bit-rate 8000000 --time-limit \(maximumDuration) '\(remoteFile)'"
            let adb = self.adb
            let arguments = ["-s", adb.serial] + ADBService.shellArguments(for: ["sh", "-c", script])
            let process = Task {
                try await ProcessRunner.run(executable: adb.sdk.adb, arguments: arguments, timeout: Double(maximumDuration + 20))
            }
            remoteTask = process
            remoteExitConfirmed = false
            Task {
                let outcome = await process.result
                self.remoteOutcome = outcome
            }
            let readyDeadline = now + 10
            while identity == nil {
                if let outcome = remoteOutcome { throw failure(outcome, fallback: "Android screenrecord exited before recording began.") }
                if let pidText = try? await shell(["cat", remotePIDFile]), let pid = Int32(pidText), pid > 0 {
                    identity = try? await readIdentity(pid: pid)
                }
                guard now < readyDeadline else { throw RecordingError("Android screenrecord did not start within 10 seconds.") }
                if identity == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            started = true
            let recordingDeadline = now + Double(maximumDuration + 5)
            while remoteOutcome == nil, !stopRequested {
                if let size = try? await remoteSize(), size > Self.maximumFileBytes {
                    throw RecordingError("Screen recording exceeded the 256 MB limit.")
                }
                guard now < recordingDeadline else { throw RecordingError("Android screenrecord exceeded its recording time limit.") }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            try await stopRemote()
            if discardRequested { throw CancellationError() }
            guard let outcome = remoteOutcome else { throw RecordingError("Android screenrecord did not report completion.") }
            let command = try outcome.get()
            guard command.status == 0 || (stopRequested && command.status == 130) else {
                throw failure(outcome, fallback: "Android screenrecord failed.")
            }
            let size = try await remoteSize()
            guard size > 32, size <= Self.maximumFileBytes else { throw RecordingError("Android returned an empty or oversized recording.") }
            let scratch = destination.deletingLastPathComponent().appendingPathComponent(".android-simulator-recording-" + identifier, isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            localDirectory = scratch
            let downloaded = scratch.appendingPathComponent("capture.mp4")
            _ = try await adb.run(["pull", remoteFile, downloaded.path], timeout: 60)
            if discardRequested { throw CancellationError() }
            let video = try await Self.inspectMP4(at: downloaded)
            guard video.bytes == size else { throw RecordingError("The recording download was incomplete.") }
            try Self.validateDestination(destination, overwriteExisting: overwriteExisting)
            guard try RecordingDestinationIdentity.read(at: destination) == expectedDestination else {
                throw RecordingError("The recording destination changed while recording. It was preserved; choose another destination and record again.")
            }
            if discardRequested { throw CancellationError() }
            // Same-directory rename publishes a fully validated file atomically.
            if overwriteExisting, expectedDestination != .absent {
                guard Darwin.rename(downloaded.path, destination.path) == 0 else {
                    throw RecordingError("Could not save recording: \(String(cString: strerror(errno)))")
                }
            } else {
                try FileManager.default.moveItem(at: downloaded, to: destination)
            }
            let cleaned = await cleanup()
            return Result(url: destination, byteCount: video.bytes, duration: video.duration,
                          width: video.width, height: video.height,
                          cleanupWarning: cleaned ? nil : "Recording saved, but temporary Android recording files could not be removed. They remain at \(remoteDirectory).")
        } catch {
            let cleaned = await cleanup()
            if !cleaned {
                throw RecordingError("\(error.localizedDescription) Temporary recording cleanup could not be confirmed on Android (\(remoteDirectory)).")
            }
            throw error
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func readIdentity(pid: Int32) async throws -> RecordingProcessIdentity {
        let stat = try await shell(["cat", "/proc/\(pid)/stat"])
        let command = try await adb.run(ADBService.shellArguments(for: ["cat", "/proc/\(pid)/cmdline"]), timeout: 3).stdout
        guard let identity = RecordingProcessIdentity(pid: pid, stat: stat, command: command, expectedOutput: remoteFile) else {
            throw RecordingError("The Android recording process identity did not match this recording.")
        }
        return identity
    }

    private func stopRemote() async throws {
        guard remoteTask != nil else { return }
        if let identity, try await remoteIsOwned(identity) { try await signal(identity, name: "INT") }
        let deadline = now + 8
        var remoteAlive = identity != nil
        while now < deadline {
            if let identity { remoteAlive = try await remoteIsOwned(identity) }
            else { remoteAlive = false }
            if !remoteAlive, remoteOutcome != nil {
                guard identity != nil else {
                    throw RecordingError("The Android recording process identity could not be established; remote cleanup could not be confirmed.")
                }
                remoteExitConfirmed = true
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if remoteAlive || remoteOutcome == nil {
            if let identity {
                try await signal(identity, name: "KILL")
                let killDeadline = now + 2
                while try await remoteIsOwned(identity) {
                    guard now < killDeadline else {
                        throw RecordingError("The owned Android recording process did not exit after forced cleanup.")
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                remoteExitConfirmed = true
            }
            remoteTask?.cancel()
            if let remoteTask { _ = await remoteTask.result }
            throw RecordingError("Android did not finalize the recording after Stop. The incomplete recording was discarded.")
        }
    }

    private func signal(_ identity: RecordingProcessIdentity, name: String) async throws {
        let script = ownershipGuard(identity) + "\nkill -\(name) \(identity.pid)"
        _ = try await shell(["sh", "-c", script])
    }

    private func remoteIsOwned(_ identity: RecordingProcessIdentity) async throws -> Bool {
        try await shell(["sh", "-c", ownershipGuard(identity) + "\nprintf owned"]) == "owned"
    }

    private func ownershipGuard(_ identity: RecordingProcessIdentity) -> String {
        // Check boot, exact start tick, executable and this unique output path
        // in the same remote shell that signals the PID. No pidof/pkill is used.
        return """
        test "$(cat /proc/sys/kernel/random/boot_id)" = '\(bootID ?? "")' || exit 0
        test -r /proc/\(identity.pid)/stat || exit 0
        test "$(awk '{print $22}' /proc/\(identity.pid)/stat)" = '\(identity.startTicks)' || exit 0
        test "$(tr '\\000' '\\n' < /proc/\(identity.pid)/cmdline | head -n 1)" = '/system/bin/screenrecord' || exit 0
        test "$(tr '\\000' '\\n' < /proc/\(identity.pid)/cmdline | tail -n 1)" = '\(remoteFile)' || exit 0
        """
    }

    private func cleanup() async -> Bool {
        var success = true
        if remoteTask != nil {
            if identity == nil, let text = try? await shell(["cat", remotePIDFile]), let pid = Int32(text), pid > 0 {
                identity = try? await readIdentity(pid: pid)
            }
            do { try await stopRemote() } catch { success = false }
        }
        if let remoteTask { remoteTask.cancel(); _ = await remoteTask.result }
        self.remoteTask = nil
        if directoryOwned, remoteExitConfirmed {
            do {
                guard let bootID, try await shell(["cat", "/proc/sys/kernel/random/boot_id"]) == bootID else {
                    throw RecordingError("Android runtime changed before recording cleanup.")
                }
                _ = try await shell(["rm", "-f", remoteFile, remotePIDFile])
                _ = try await shell(["rmdir", remoteDirectory])
                directoryOwned = false
            } catch { success = false }
        } else if directoryOwned {
            // Do not unlink a file that an unconfirmed remote process may
            // still be writing. The Android command retains its own time cap.
            success = false
        }
        if let localDirectory {
            let file = localDirectory.appendingPathComponent("capture.mp4")
            do {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                guard Darwin.rmdir(localDirectory.path) == 0 else { throw RecordingError("Could not remove the private recording download folder.") }
                self.localDirectory = nil
            } catch { success = false }
        }
        cleanupSucceeded = success
        return success
    }

    private func remoteSize() async throws -> Int64 {
        let text = try await shell(["stat", "-c", "%s", remoteFile])
        guard let size = Int64(text), size >= 0 else { throw RecordingError("Android returned an invalid recording size.") }
        return size
    }

    private func shell(_ arguments: [String]) async throws -> String {
        try await adb.run(ADBService.shellArguments(for: arguments), timeout: 3).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func failure(_ outcome: Swift.Result<CommandResult, Error>, fallback: String) -> Error {
        switch outcome {
        case .failure(let error): return error
        case .success(let result):
            let details = String((result.stderrText + "\n" + result.text).suffix(8_192)).trimmingCharacters(in: .whitespacesAndNewlines)
            return RecordingError(fallback + (details.isEmpty ? "" : "\n" + details))
        }
    }

    static func validateDestination(_ destination: URL, overwriteExisting: Bool) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "mp4" else { throw RecordingError("Choose a local .mp4 recording destination.") }
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory) {
            guard !directory.boolValue, overwriteExisting else { throw RecordingError("The recording destination already exists. Choose another name or confirm replacement.") }
        }
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &directory), directory.boolValue else {
            throw RecordingError("The recording destination folder does not exist.")
        }
    }

    static func inspectMP4(at url: URL) async throws -> (bytes: Int64, duration: Double, width: Int, height: Int) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 32, bytes <= maximumFileBytes else { throw RecordingError("The recording is empty or exceeds the 256 MB limit.") }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, let track = tracks.first else { throw RecordingError("The recording does not contain a finalized video track.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { throw RecordingError("The recording video format could not be decoded.") }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(), let image = CMSampleBufferGetImageBuffer(sample) else {
            throw RecordingError("The recording contains no decodable video frame.")
        }
        let dimensions = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
        reader.cancelReading()
        return (bytes, duration, dimensions.0, dimensions.1)
    }
}

struct RecordingProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let startTicks: UInt64
    init?(pid: Int32, stat: String, command: Data, expectedOutput: String) {
        let tokens = command.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard pid > 0, tokens.first == "/system/bin/screenrecord", tokens.last == expectedOutput,
              let open = stat.firstIndex(of: "("), Int32(stat[..<open].trimmingCharacters(in: .whitespaces)) == pid,
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 19, let ticks = UInt64(fields[19]), ticks > 0 else { return nil }
        self.pid = pid; startTicks = ticks
    }
}

enum RecordingDestinationIdentity: Equatable, Sendable {
    case absent
    case file(device: Int32, inode: UInt64, size: Int64, modifiedSeconds: Int, modifiedNanoseconds: Int, mode: UInt16)
    static func read(at url: URL) throws -> RecordingDestinationIdentity {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 {
            return .file(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                         modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec, mode: info.st_mode)
        }
        guard errno == ENOENT else { throw RecordingError("The recording destination could not be inspected: \(String(cString: strerror(errno)))") }
        return .absent
    }
}

private struct RecordingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

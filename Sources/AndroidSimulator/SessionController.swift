import AppKit
import Combine
import CoreVideo
import SimulatorKit

final class LogMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var scheduled = false
    func put(_ batch: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        lines = Array((lines + batch).suffix(500))
        var bytes = lines.reduce(0) { $0 + $1.utf8.count }
        while bytes > 2_097_152, !lines.isEmpty { bytes -= lines.removeFirst().utf8.count }
        if scheduled { return false }; scheduled = true; return true
    }
    func take() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let result = lines; lines = []; scheduled = false; return result
    }
}

/// Only the log viewport observes this document. Streaming log batches must not
/// invalidate the device controls, presentation surface, or application library.
@MainActor
final class LogPresentation: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    @Published var paused = false
    private var buffer = LogTextBuffer()

    var lines: [String] { buffer.lines }
    var text: String { buffer.text }
    func filteredText(matching query: String) -> String { buffer.filteredText(matching: query) }
    @discardableResult
    func append(_ incoming: [String]) -> Bool {
        guard buffer.append(incoming, paused: paused) else { return false }
        revision = buffer.revision
        return true
    }
}

enum DeveloperPanelKind: Equatable { case logs, diagnostics }

final class FrameStore: @unchecked Sendable {
    struct SurfaceMeasurement: Sendable {
        var streamID: UUID?
        var decodedFrames = 0
        var submittedFrames = 0
        var counters = PresentationDiagnostics.Snapshot()
    }
    private let lock = NSLock()
    let inputLatency = InputFrameLatencyTracker()
    private let presentationDiagnostics = PresentationDiagnostics()
    private var pending: DecodedFrame?
    private var total = 0
    private var dropped = 0
    private var delay = 0.0
    private var submittedCount = 0
    private var receiveToSubmitMilliseconds = 0.0
    private var activeStream: UUID?
    private var receivedFrame = false
    private var size = CGSize.zero
    private var streamDecodedBaseline = 0
    private var streamSubmittedBaseline = 0
    func beginStream(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        activeStream = id; pending = nil; receivedFrame = false
        inputLatency.clearPending()
        streamDecodedBaseline = total; streamSubmittedBaseline = submittedCount
        presentationDiagnostics.reset(at: ProcessInfo.processInfo.systemUptime)
    }
    func put(_ frame: DecodedFrame, stream: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard stream == activeStream else { return }
        if pending != nil { dropped += 1 }
        pending = frame; total += 1; receivedFrame = true
        size = CGSize(width: frame.width, height: frame.height)
        delay = max(0, (frame.decodedAt - frame.receivedAt) * 1000)
    }
    func dimensions() -> CGSize { lock.lock(); defer { lock.unlock() }; return size }
    func hasFrame(for stream: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeStream == stream && receivedFrame
    }
    func take() -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending = nil; return result
    }
    func stats() -> (Int, Int, Double) {
        lock.lock(); defer { lock.unlock() }; return (total, dropped, delay)
    }
    func submitted(_ frame: DecodedFrame) {
        lock.lock(); defer { lock.unlock() }
        submittedCount += 1
        receiveToSubmitMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - frame.receivedAt) * 1000)
        inputLatency.submitted(frameReceivedAt: frame.receivedAt, at: ProcessInfo.processInfo.systemUptime)
    }
    func presentationStats() -> (count: Int, receiveToSubmitMilliseconds: Double) {
        lock.lock(); defer { lock.unlock() }; return (submittedCount, receiveToSubmitMilliseconds)
    }
    func recordPresentationTick(at startedAt: TimeInterval, completedAt: TimeInterval,
                                outcome: PresentationDiagnostics.Outcome,
                                layerStatus: PresentationDiagnostics.LayerStatus,
                                flushCount: UInt64, layerError: String?) {
        lock.lock(); defer { lock.unlock() }
        guard activeStream != nil else { return }
        presentationDiagnostics.recordTick(at: startedAt, completedAt: completedAt, outcome: outcome,
            layerStatus: layerStatus, flushCount: flushCount, layerError: layerError)
    }
    var surfaceMetrics: SurfaceMeasurement {
        lock.lock(); defer { lock.unlock() }
        return SurfaceMeasurement(streamID: activeStream,
            decodedFrames: total - streamDecodedBaseline,
            submittedFrames: submittedCount - streamSubmittedBaseline,
            counters: presentationDiagnostics.snapshot)
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        pending = nil; activeStream = nil; receivedFrame = false
        inputLatency.clearPending()
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = nil; activeStream = nil; receivedFrame = false
        total = 0; dropped = 0; delay = 0; submittedCount = 0; receiveToSubmitMilliseconds = 0
        inputLatency.reset()
        presentationDiagnostics.reset()
        streamDecodedBaseline = 0; streamSubmittedBaseline = 0
    }
}

@MainActor
final class SessionController: ObservableObject, Identifiable {
    let id = UUID()
    let avd: AVD
    let sdk: SDKInstallation
    let frames = FrameStore()
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var status = "Ready to start"
    @Published private(set) var fps = 0.0
    @Published private(set) var submittedFPS = 0.0
    @Published private(set) var receiveToSubmitMilliseconds = 0.0
    @Published private(set) var resources: ProcessResourceUsage?
    @Published private(set) var surfaceMetrics = FrameStore.SurfaceMeasurement()
    private let resourceSampler = ProcessResourceSampler()
    @Published private(set) var droppedFrames = 0
    @Published private(set) var decodeMilliseconds = 0.0
    @Published var error: String?
    @Published private(set) var actionStatus: String?
    @Published private(set) var adbAvailable = false
    @Published private(set) var runtime: RunningEmulator?
    let logPresentation = LogPresentation()
    var logLines: [String] { logPresentation.lines }
    var logPaused: Bool {
        get { logPresentation.paused }
        set { logPresentation.paused = newValue }
    }
    @Published private(set) var displayedDiagnostics = ""
    private var diagnosticsVisible = false
    private let manager: EmulatorProcessManager
    private let runtimeLedger: RuntimeLedger
    private let failureEvidenceStore: RuntimeFailureEvidenceStore
    @Published private(set) var lastRuntimeFailure: RuntimeFailureEvidenceStore.Record?
    private var preservingRuntimeFailure = false
    private let isQuitting: @MainActor () -> Bool
    private let bridgeFactory: @MainActor (ADBService, URL) -> any DisplayBridge
    @Published private(set) var historyWarning: String?
    private let journal: SessionEventLog?
    private var bridge: (any DisplayBridge)?
    private var rotation: GuestRotation?
    private var rotationTask: Task<Void, Never>?
    @Published private(set) var rotating = false
    @Published private(set) var versions: RuntimeVersionInfo?
    private var logStreamEnded = false
    private var gpuMode = "host"
    private var windowVisible = true
    @Published private(set) var displayAttached = false
    @Published private(set) var recordingActive = false
    private var recording: ScreenRecording?
    private var recordingStart: Task<Void, Error>?
    private var recordingObserver: Task<Void, Never>?
    @Published private(set) var snapshots: [EmulatorSnapshot] = []
    @Published private(set) var snapshotBusy = false
    @Published private var unsupportedSnapshots: (runtimeID: UUID, reason: String)?
    private var snapshotTask: Task<Void, Never>?
    private var backgroundDetachTask: Task<Void, Never>?
    private var backgroundDetachID: UUID?
    private var lifecycle: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var logsTask: Task<Void, Never>?
    private var logsID: UUID?
    private var logsRequested = false
    private var retiringLogs: [UUID: Task<Void, Never>] = [:]
    private var developerActions: [UUID: Task<Void, Never>] = [:]
    private var reconnecting = false
    private var generation = 0
    private var bridgeID: UUID?
    private var bridgeFailure: String?
    private(set) var lastRuntimeLogURL: URL?
    var adb: ADBService? { runtime.map { ADBService(sdk: sdk, serial: $0.serial) } }
    var isActive: Bool { state != .idle && state != .failed && state != .stopping }
    var hasPendingWork: Bool { !developerActions.isEmpty || recordingActive || snapshotBusy || backgroundDetachTask != nil || !retiringLogs.isEmpty || preservingRuntimeFailure }
    var canControl: Bool { !isQuitting() && state == .running && displayAttached && !snapshotBusy }
    var snapshotUnsupportedReason: String? {
        guard let unsupportedSnapshots, unsupportedSnapshots.runtimeID == runtime?.id else { return nil }
        return unsupportedSnapshots.reason
    }
    var canManageSnapshots: Bool { state == .running && canUseADB && snapshotUnsupportedReason == nil && !snapshotBusy && !recordingActive && !rotating && !reconnecting && lifecycle == nil }
    var canUseADB: Bool { !isQuitting() && !snapshotBusy && adbAvailable && state != .stopping && state != .idle && runtime?.process.isRunning == true }

    init(avd: AVD, sdk: SDKInstallation,
         manager: EmulatorProcessManager = EmulatorProcessManager(),
         runtimeLedger: RuntimeLedger? = nil, journalURL: URL? = nil,
         failureEvidenceStore: RuntimeFailureEvidenceStore = .shared,
         isQuitting: @escaping @MainActor () -> Bool = { AppModel.shared.isQuitting },
         bridgeFactory: @escaping @MainActor (ADBService, URL) -> any DisplayBridge = { ScrcpyRuntimeAdapter.makeBridge(adb: $0, serverURL: $1) }) {
        self.avd = avd; self.sdk = sdk
        self.manager = manager
        self.runtimeLedger = runtimeLedger ?? AppModel.shared.runtimeLedger
        self.failureEvidenceStore = failureEvidenceStore
        self.isQuitting = isQuitting; self.bridgeFactory = bridgeFactory
        let url = journalURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AndroidSimulator/session-\(id.uuidString).jsonl")
        self.journal = try? SessionEventLog(url: url)
    }
    private func transition(_ newState: SessionState, _ message: String) {
        guard state == newState || state.canTransition(to: newState) else { return }
        state = newState; status = message
        journal?.append(sessionID: id.uuidString, state: newState.rawValue, message: message)
        refreshDisplayedDiagnostics()
    }
    static var serverURL: URL? {
        if let url = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) { return url }
        let candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/scrcpy-server"), Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/scrcpy-server")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    func start(coldBoot: Bool = false, wipeData: Bool = false) {
        guard !isQuitting(), state == .idle || state == .failed else { return }
        // Opening a device after a display failure must preserve the living VM.
        if !coldBoot, !wipeData, runtime?.process.isRunning == true { retryDisplay(); return }
        error = nil; lastRuntimeFailure = nil; generation += 1; let token = generation
        let previousLifecycle = lifecycle, previousReconnect = reconnectTask, previousMonitor = monitor, previousLogs = logsTask
        previousLifecycle?.cancel(); previousReconnect?.cancel(); previousMonitor?.cancel(); previousLogs?.cancel()
        reconnectTask = nil; monitor = nil; logsTask = nil; reconnecting = false
        transition(.starting, "Starting headless emulator…")
        lifecycle = Task {
            defer { if generation == token { lifecycle = nil } }
            do {
                // A failed operation may still be releasing its exact resources.
                // Join it before allowing a replacement launch to own new ones.
                await previousLifecycle?.value; await previousReconnect?.value
                await previousMonitor?.value; await previousLogs?.value
                try checkOperation(token)
                await stopResources()
                try checkOperation(token)
                versions = await ScrcpyRuntimeAdapter.inspectVersions(sdk: sdk)
                try checkOperation(token)
                gpuMode = UserDefaults.standard.string(forKey: "gpuMode") ?? "host"
                frames.reset(); snapshots = []; fps = 0; droppedFrames = 0; decodeMilliseconds = 0; actionStatus = nil
                guard Self.serverURL != nil else { throw AppFailure("The display server is missing. Rebuild the application using scripts/build.sh.") }
                let running = try await manager.launch(sdk: sdk, avd: avd, coldBoot: coldBoot, gpuMode: gpuMode, wipeData: wipeData)
                guard generation == token, !Task.isCancelled else { await manager.stop(running); return }
                runtime = running; lastRuntimeLogURL = running.logURL
                unsupportedSnapshots = nil
                await recordRuntimeHistory(running)
                try checkOperation(token)
                transition(.booting, "Waiting for Android to finish booting…")
                let adb = ADBService(sdk: sdk, serial: running.serial)
                let deadline = Date().addingTimeInterval(180)
                var ready = false
                while Date() < deadline {
                    try checkOperation(token)
                    guard running.process.isRunning else { throw AppFailure("The emulator exited during boot. Open diagnostics to inspect the runtime log.") }
                    let value = try? await adb.shell(["getprop", "sys.boot_completed"])
                    try checkOperation(token)
                    if value?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { ready = true; break }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard ready else { throw AppFailure("Android did not finish booting within 180 seconds. Check the runtime log, then retry or choose Cold Boot.") }
                await recordRuntimeHistory(running)
                try checkOperation(token)
                adbAvailable = true
                transition(.connecting, "Connecting live display…")
                try await connectBridge(token: token)
                try checkOperation(token)
                beginMonitoring(token: token)
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                if let exited = runtime, !exited.process.isRunning {
                    await preserveUnexpectedRuntimeExit(exited, operationToken: token)
                    return
                }
                self.error = error.localizedDescription
                stopLogs()
                if runtime?.process.isRunning == true, adbAvailable {
                    // Android already booted. A first display failure has the
                    // same bridge-only recovery policy as a later disconnect.
                    transition(.reconnecting, "Android booted; retrying its display…")
                    beginMonitoring(token: token)
                    reconnect(reason: error.localizedDescription)
                    return
                }
                await stopResources()
                guard token == generation, !Task.isCancelled else { return }
                transition(.failed, "Could not start this device")
            }
        }
    }
    private func checkOperation(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }
    private func connectBridge(token: Int) async throws {
        try checkOperation(token)
        guard let adb, let serverURL = Self.serverURL else { throw AppFailure("Display bridge prerequisites are unavailable.") }
        let next = bridgeFactory(adb, serverURL)
        let attempt = UUID()
        bridge = next; bridgeID = attempt; bridgeFailure = nil
        let store = frames
        store.beginStream(attempt)
        surfaceMetrics = store.surfaceMetrics
        do {
            try await next.start(onFrame: { frame in store.put(frame, stream: attempt) }, onDisconnect: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == token, self.bridgeID == attempt else { return }
                    self.bridgeFailure = message
                    // During negotiation, the awaiting operation handles failure.
                    if self.state == .running { self.reconnect(reason: message) }
                }
            })
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while true {
                try checkOperation(token)
                guard bridgeID == attempt else { throw CancellationError() }
                guard runtime?.process.isRunning == true else { throw AppFailure("The emulator exited while connecting its display.") }
                if let bridgeFailure { throw AppFailure(bridgeFailure) }
                if store.hasFrame(for: attempt) { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw AppFailure("The display connected but produced no decoded frame within 20 seconds. Open diagnostics and retry the display.")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            // A valid handshake alone does not prove a usable video pipeline.
            displayAttached = true
            transition(.running, "Android is ready")
            if !windowVisible { let previous = detachBridge(); await previous?.stop(); status = "Android is running in the background" }
        } catch {
            if bridgeID == attempt { _ = detachBridge() }
            await next.stop()
            throw error
        }
    }
    private func beginMonitoring(token: Int) {
        monitor?.cancel()
        monitor = Task {
            var previous = frames.stats().0
            var previousSubmitted = frames.presentationStats().count
            var previousTime = ProcessInfo.processInfo.systemUptime
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard token == generation, !Task.isCancelled else { return }
                guard let runtime else { return }
                guard runtime.process.isRunning else {
                    await preserveUnexpectedRuntimeExit(runtime, operationToken: token)
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime, elapsed = max(0.001, now - previousTime)
                let stats = frames.stats(); fps = Double(stats.0 - previous) / elapsed; previous = stats.0
                let presentation = frames.presentationStats(); submittedFPS = Double(presentation.count - previousSubmitted) / elapsed
                previousSubmitted = presentation.count; previousTime = now
                receiveToSubmitMilliseconds = presentation.receiveToSubmitMilliseconds
                resources = resourceSampler.sample(pid: runtime.process.processIdentifier)
                surfaceMetrics = frames.surfaceMetrics
                droppedFrames = stats.1; decodeMilliseconds = stats.2
                refreshDisplayedDiagnostics()
                ticks += 1
                if ticks % 5 == 0, let adb {
                    let available = (try? await adb.run(["get-state"], timeout: 3).text.trimmingCharacters(in: .whitespacesAndNewlines)) == "device"
                    guard token == generation, !Task.isCancelled else { return }
                    adbAvailable = available
                }
            }
        }
    }
    private func preserveUnexpectedRuntimeExit(_ exited: RunningEmulator, operationToken: Int) async {
        guard generation == operationToken, runtime?.id == exited.id, !exited.process.isRunning else { return }
        let reason: String
        switch exited.process.terminationReason {
        case .exit: reason = "normal exit"
        case .uncaughtSignal: reason = "uncaught signal"
        @unknown default: reason = "unknown termination"
        }
        let exit = RuntimeFailureEvidenceStore.Exit(runtimeID: exited.id, sessionID: id,
            processID: exited.process.processIdentifier, serial: exited.serial, avdName: exited.avdName,
            consolePort: exited.consolePort, status: exited.process.terminationStatus, reason: reason)
        generation += 1
        let failureGeneration = generation
        preservingRuntimeFailure = true
        defer { preservingRuntimeFailure = false }
        lifecycle?.cancel(); reconnectTask?.cancel(); reconnecting = false
        stopLogs()
        lastRuntimeFailure = RuntimeFailureEvidenceStore.Record(exit: exit)
        error = exit.message
        surfaceMetrics = frames.surfaceMetrics
        transition(.failed, "Emulator stopped unexpectedly")
        // Capture exact identity and observations before cleanup clears runtime.
        let snapshot = currentDiagnostics
        let logText = logPresentation.text
        let journalURL = journal?.url
        await stopResources()
        _ = await journal?.flush()
        let store = failureEvidenceStore
        // Stop, Quit or a fresh Start may cancel the original monitor/lifecycle.
        // They still join it, and this bounded local preservation survives that
        // cancellation without publishing an old failure into a new generation.
        let record = await Task.detached(priority: .utility) {
            let drained = await exited.waitForLogDrain(timeout: 2)
            return await store.preserve(exit: exit, diagnosticsString: snapshot, runtimeLogURL: exited.logURL,
                journalURL: journalURL, logLinesString: logText,
                runtimeLogWarning: drained ? nil : "Runtime log EOF was not observed within 2 seconds; the captured stdout/stderr tail and emulator.log may be incomplete.")
        }.value
        // A user Stop may have advanced generation while joining this work.
        // Complete that same historical record, but never replace a newer one
        // (Start clears it) or overwrite a newer lifecycle's status/error.
        guard lastRuntimeFailure?.exit.runtimeID == exited.id else { return }
        lastRuntimeFailure = record
        if generation == failureGeneration, state == .failed { error = record.message }
        refreshDisplayedDiagnostics()
    }
    func reconnect(reason: String = "Reconnecting display…") {
        guard !reconnecting, let runtime, runtime.process.isRunning, state == .running || state == .reconnecting || state == .failed else { return }
        reconnecting = true
        // Failed display sessions retain an owned guest and support an explicit
        // bridge-only retry, even though the general state model starts afresh.
        if state == .failed { state = .reconnecting }
        transition(.reconnecting, "Reconnecting display; Android is still running…")
        let token = generation
        reconnectTask = Task {
            defer { if token == generation { reconnecting = false; reconnectTask = nil } }
            await backgroundDetachTask?.value
            guard token == generation, !Task.isCancelled else { return }
            let previous = detachBridge()
            await previous?.stop()
            for attempt in 1...3 {
                guard token == generation, !Task.isCancelled, state == .reconnecting else { return }
                do {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    try checkOperation(token)
                    try await connectBridge(token: token)
                    try checkOperation(token)
                    error = nil; beginMonitoring(token: token); return
                } catch {
                    guard token == generation, !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
            }
            guard token == generation, !Task.isCancelled else { return }
            stopLogs(); fps = 0
            transition(.failed, "Display unavailable. The emulator is still running.")
            error = "The display connection could not be restored. \(reason) Use Retry Display to reconnect without rebooting."
            // A retained guest still needs exit, ADB and resource monitoring.
            beginMonitoring(token: token)
        }
    }
    func retryDisplay() {
        guard !snapshotBusy, !reconnecting, state == .idle || state == .failed || state == .running else { return }
        guard runtime?.process.isRunning == true else { start(); return }
        reconnect(reason: "Manual retry")
    }
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        if visible {
            if runtime?.process.isRunning == true, state == .running, !displayAttached { retryDisplay() }
        } else {
            stopLogs()
            guard state == .running, backgroundDetachTask == nil else { return }
            let token = generation, request = UUID(), runtimeID = runtime?.id
            backgroundDetachID = request
            backgroundDetachTask = Task {
                defer {
                    if backgroundDetachID == request { backgroundDetachTask = nil; backgroundDetachID = nil }
                }
                guard token == generation, !windowVisible, state == .running else { return }
                let previous = detachBridge(); await previous?.stop()
                if token == generation, !windowVisible, state == .running, runtime?.id == runtimeID {
                    status = "Android is running in the background"
                }
            }
        }
    }
    func rotate() {
        guard canControl, adbAvailable, !rotating, !recordingActive, let adb else { return }
        rotating = true; let token = generation
        let controller = rotation ?? GuestRotation(adb: adb); rotation = controller
        rotationTask = Task {
            defer { rotating = false; rotationTask = nil }
            do {
                let previous = frames.dimensions()
                try await controller.rotate(to: previous.height > previous.width ? 1 : 0)
                try checkOperation(token)
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                while frames.dimensions() == previous {
                    try checkOperation(token)
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppFailure("Android did not rotate its display. This app may lock its orientation.") }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch is CancellationError { }
            catch { if token == generation { self.error = error.localizedDescription } }
        }
    }
    func send(_ input: BridgeInput) {
        guard canControl || input.isRelease, let bridge else { return }
        if !input.isRelease { frames.inputLatency.recordInput(at: ProcessInfo.processInfo.systemUptime) }
        bridge.send(input)
    }
    func key(_ code: UInt32) { send(.key(code: code, down: true)); send(.key(code: code, down: false)) }
    func copyAndroidClipboard() {
        guard canControl, let bridge else { return }
        let token = generation, attempt = bridgeID, request = UUID()
        actionStatus = "Reading Android clipboard…"
        developerActions[request] = Task {
            defer { developerActions[request] = nil }
            do {
                let text = try await bridge.readClipboard()
                try checkOperation(token)
                guard bridgeID == attempt else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                actionStatus = "Android clipboard copied to Mac"
            } catch is CancellationError { }
            catch { if token == generation, bridgeID == attempt { self.error = error.localizedDescription; actionStatus = nil } }
        }
    }
    func stop() async {
        if let shutdownTask { await shutdownTask.value; return }
        guard state != .idle else { generation += 1; await backgroundDetachTask?.value; await joinLogCleanup(); await cancelDeveloperActions(); return }
        generation += 1; let token = generation
        let pendingLifecycle = lifecycle, pendingReconnect = reconnectTask, pendingMonitor = monitor, pendingLogs = logsTask
        pendingLifecycle?.cancel(); pendingReconnect?.cancel(); pendingMonitor?.cancel(); pendingLogs?.cancel()
        lifecycle = nil; reconnectTask = nil; monitor = nil; logsTask = nil; reconnecting = false
        // A failed display can still own a live VM and must also be stoppable.
        state = .stopping; status = "Stopping emulator…"
        journal?.append(sessionID: id.uuidString, state: "stopping", message: status)
        refreshDisplayedDiagnostics()
        let shutdown = Task {
            await stopResources()
            // Launch can return after stop was requested. Its token check stops
            // that exact child; wait for it before reporting the session idle.
            await pendingLifecycle?.value; await pendingReconnect?.value
            await pendingMonitor?.value; await pendingLogs?.value
        }
        shutdownTask = shutdown
        await shutdown.value
        guard generation == token else { return }
        shutdownTask = nil
        fps = 0
        transition(.idle, "Device stopped")
        _ = await journal?.flush()
    }
    func restart(coldBoot: Bool = false, wipeData: Bool = false) async {
        await stop()
        start(coldBoot: coldBoot, wipeData: wipeData)
    }
    func leaveRunningForQuit() async {
        if let shutdownTask { await shutdownTask.value; return }
        // Finish cancellation/bridge cleanup while intentionally retaining a
        // runtime whose ownership has already been established.
        guard runtime?.process.isRunning == true else { await stop(); return }
        state = .stopping; status = "Disconnecting; Android will remain running…"
        refreshDisplayedDiagnostics()
        generation += 1
        let pendingLifecycle = lifecycle, pendingReconnect = reconnectTask, pendingMonitor = monitor, pendingLogs = logsTask
        pendingLifecycle?.cancel(); pendingReconnect?.cancel(); pendingMonitor?.cancel(); pendingLogs?.cancel()
        lifecycle = nil; reconnectTask = nil; monitor = nil; logsTask = nil
        await backgroundDetachTask?.value
        await joinLogCleanup()
        await cancelDeveloperActions()
        await snapshotTask?.value
        await finishRecording()
        let rotatingTask = rotationTask; rotatingTask?.cancel(); await rotatingTask?.value
        await restoreRotation()
        let previous = detachBridge()
        await previous?.stop()
        await pendingLifecycle?.value; await pendingReconnect?.value
        await pendingMonitor?.value; await pendingLogs?.value
        if let runtime, runtime.process.isRunning {
            do {
                // Boot may have exec'd QEMU since the initial record, or a
                // damaged ledger may have been reset while this guest ran.
                try await runtimeLedger.record(runtime: runtime, sdk: sdk)
                try await runtimeLedger.markLeftRunning(id: runtime.id)
            }
            catch { reportHistoryFailure(error) }
        }
    }
    private func detachBridge() -> (any DisplayBridge)? {
        let previous = bridge
        bridge = nil; bridgeID = nil; bridgeFailure = nil; displayAttached = false; frames.clear()
        refreshDisplayedDiagnostics()
        return previous
    }
    private func stopResources() async {
        await backgroundDetachTask?.value
        await snapshotTask?.value
        await joinLogCleanup()
        await cancelDeveloperActions()
        await finishRecording()
        let rotatingTask = rotationTask; rotatingTask?.cancel(); await rotatingTask?.value
        await restoreRotation()
        // Detach before suspension so old cleanup cannot clear a newer session.
        let previousBridge = detachBridge(), previousRuntime = runtime
        runtime = nil; adbAvailable = false; fps = 0; submittedFPS = 0; resources = nil
        await previousBridge?.stop()
        if let previousRuntime {
            await manager.stop(previousRuntime)
            if !previousRuntime.process.isRunning {
                do { try await runtimeLedger.remove(id: previousRuntime.id) }
                catch { reportHistoryFailure(error) }
            }
        }
        // A controller targets the old serial; never carry it into a new VM.
        rotation = nil
        refreshDisplayedDiagnostics()
    }
    private func recordRuntimeHistory(_ running: RunningEmulator) async {
        let token = generation
        do {
            try await runtimeLedger.record(runtime: running, sdk: sdk)
            if token == generation, runtime?.id == running.id { historyWarning = nil }
        } catch {
            if token == generation, runtime?.id == running.id { reportHistoryFailure(error) }
        }
    }
    private func reportHistoryFailure(_ failure: Error) {
        historyWarning = failure.localizedDescription
        journal?.append(sessionID: id.uuidString, state: state.rawValue, message: "Runtime history: \(failure.localizedDescription)")
    }
    private func restoreRotation() async {
        guard let controller = rotation else { return }
        if await controller.restore() {
            if rotation === controller { rotation = nil }
        } else {
            let message = "Android's original rotation settings could not be restored because ADB is unavailable. Check rotation in Android Settings when it reconnects."
            error = message
            journal?.append(sessionID: id.uuidString, state: state.rawValue, message: message)
            _ = await journal?.flush()
        }
    }
    /// Terminal operations participate in the same selected-runtime cancellation
    /// and cleanup as native developer actions; Stop/Quit join the ADB client.
    func runTerminalADBAction(_ operation: @escaping @MainActor (ADBService) async throws -> String) async throws -> String {
        guard let adb, canUseADB, state == .running else {
            throw AppFailure("ADB is unavailable. Boot the device and wait for it to reconnect.")
        }
        let token = generation, request = UUID()
        let operationTask = Task { @MainActor in
            try checkOperation(token)
            let message = try await operation(adb)
            try checkOperation(token)
            actionStatus = message
            return message
        }
        developerActions[request] = Task {
            await withTaskCancellationHandler {
                _ = await operationTask.result
            } onCancel: { operationTask.cancel() }
        }
        defer { developerActions[request] = nil }
        return try await withTaskCancellationHandler {
            try await operationTask.value
        } onCancel: { operationTask.cancel() }
    }
    func install(_ url: URL) {
        guard let adb, canUseADB else { error = "ADB is unavailable. Wait for the device to reconnect."; return }
        guard url.pathExtension.lowercased() == "apk" else { error = "Choose an Android APK file."; return }
        let token = generation, request = UUID()
        actionStatus = "Installing \(url.lastPathComponent)…"
        developerActions[request] = Task {
            defer { developerActions[request] = nil }
            do {
                try checkOperation(token)
                try await adb.install(apk: url)
                try checkOperation(token)
                actionStatus = "Installed \(url.lastPathComponent)"
            } catch is CancellationError { }
            catch { if token == generation { self.error = error.localizedDescription; actionStatus = nil } }
        }
    }
    func capture() {
        guard let adb, canUseADB else { error = "ADB is unavailable. Screenshot requires a connected device."; return }
        let token = generation
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        if let path = UserDefaults.standard.string(forKey: "captureDirectory"), !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        panel.nameFieldStringValue = "\(avd.name)-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).png"
        presentDevicePanel(panel) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, token == self.generation, self.canUseADB else { return }
                let request = UUID()
                self.developerActions[request] = Task {
                    defer { self.developerActions[request] = nil }
                    do {
                        try self.checkOperation(token)
                        try await adb.screenshot(to: url)
                        try self.checkOperation(token)
                        self.actionStatus = "Screenshot saved"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch is CancellationError { }
                    catch { if token == self.generation { self.error = error.localizedDescription } }
                }
            }
        }
    }
    func chooseAPK() {
        guard canUseADB else { return }
        let token = generation
        // APK is not a declared UTType on every Mac. Filter by extension rather
        // than relying on Launch Services to classify a dynamic archive type.
        let panel = NSOpenPanel(), filter = APKPanelFilter()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.delegate = filter
        panel.title = "Install APK"; panel.prompt = "Install"
        presentDevicePanel(panel) { [weak self] result in
            withExtendedLifetime(filter) {
                guard result == .OK, let url = panel.url else { return }
                Task { @MainActor in guard let self, token == self.generation else { return }; self.install(url) }
            }
        }
    }
    func exportDiagnosticsBundle() {
        guard !isQuitting(), state != .stopping else { return }
        let token = generation
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(avd.name)-diagnostics.zip"
        panel.message = "Includes session diagnostics and recent runtime, session, and Android logs."
        presentDevicePanel(panel) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, token == self.generation, !self.isQuitting() else { return }
                let request = UUID()
                self.actionStatus = "Exporting diagnostics…"
                self.developerActions[request] = Task {
                    defer { self.developerActions[request] = nil }
                    do {
                        _ = await self.journal?.flush()
                        try self.checkOperation(token)
                        try await DiagnosticsBundle.export(destinationURL: url, diagnosticsString: self.diagnostics,
                            runtimeLogURL: self.lastRuntimeLogURL, journalURL: self.journal?.url,
                            logLinesString: self.logPresentation.text)
                        try self.checkOperation(token)
                        self.actionStatus = "Diagnostics bundle saved"
                    } catch is CancellationError { }
                    catch { if token == self.generation { self.error = error.localizedDescription; self.actionStatus = nil } }
                }
            }
        }
    }
    func chooseRecording() {
        guard canUseADB, !recordingActive, !rotating, let adb else { return }
        let token = generation
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(avd.name)-recording.mp4"
        panel.message = "Records up to three minutes of Android video without audio. Keep Android's orientation fixed while recording."
        if let path = UserDefaults.standard.string(forKey: "captureDirectory"), !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        presentDevicePanel(panel) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, token == self.generation, self.canUseADB, !self.recordingActive, !self.rotating else { return }
                let recorder = ScreenRecording(adb: adb)
                self.recording = recorder; self.recordingActive = true
                self.actionStatus = "Starting recording…"
                let approvedReplacement = FileManager.default.fileExists(atPath: url.path)
                let starting = Task { try await recorder.start(to: url, overwriteExisting: approvedReplacement) }
                self.recordingStart = starting
                self.recordingObserver = Task {
                    defer {
                        if self.recording === recorder {
                            self.recording = nil; self.recordingActive = false
                            self.recordingStart = nil; self.recordingObserver = nil
                        }
                    }
                    do {
                        try await starting.value
                        if token == self.generation { self.actionStatus = "Recording Android video…" }
                        let saved = try await recorder.waitForCompletion()
                        if token == self.generation {
                            self.actionStatus = "Recording saved: \(saved.url.lastPathComponent)"
                            if let warning = saved.cleanupWarning { self.error = warning }
                        }
                    } catch {
                        if token == self.generation { self.error = error.localizedDescription; self.actionStatus = nil }
                    }
                }
            }
        }
    }
    func finishRecording() async {
        guard let recorder = recording else { return }
        let starting = recordingStart, observer = recordingObserver, token = generation
        // Registration and startup finish before stop is requested, including
        // Stop/Quit arriving immediately after the destination was selected.
        _ = await starting?.result
        do {
            let saved = try await recorder.finish()
            if token == generation, recording === recorder {
                actionStatus = "Recording saved: \(saved.url.lastPathComponent)"
                if let warning = saved.cleanupWarning { error = warning }
            }
        } catch {
            if token == generation, recording === recorder { self.error = error.localizedDescription }
            journal?.append(sessionID: id.uuidString, state: state.rawValue, message: "Recording: \(error.localizedDescription)")
            _ = await recorder.cancel()
        }
        await observer?.value
    }
    func performSnapshot(_ action: SnapshotAction, expectedRuntimeID: UUID? = nil) {
        guard canManageSnapshots, let adb, let runtimeID = runtime?.id else { return }
        if action.requiresConfirmation, expectedRuntimeID == nil || expectedRuntimeID != runtime?.id {
            error = "The device restarted after this snapshot action was selected. Refresh snapshots and confirm the action again."
            return
        }
        let token = generation, service = EmulatorSnapshots(adb: adb)
        snapshotBusy = true
        error = nil; actionStatus = action.progress
        snapshotTask = Task {
            defer { snapshotBusy = false; snapshotTask = nil }
            var operationError: String?
            var unsupportedReason: String?
            let quiesce = action.replacesRuntimeState
            do {
                try checkOperation(token)
                if quiesce {
                    // A saved guest must not contain a live bridge server with
                    // host sockets that would become stale on restore.
                    let previousMonitor = monitor, previousLogs = logsTask
                    monitor?.cancel(); monitor = nil; stopLogs(preservingRequest: true)
                    transition(.reconnecting, action.progress)
                    await cancelDeveloperActions()
                    actionStatus = action.progress
                    await previousMonitor?.value; await previousLogs?.value
                    await backgroundDetachTask?.value
                    await joinLogCleanup()
                    try checkOperation(token)
                    await restoreRotation()
                    guard rotation == nil else { throw AppFailure("Restore Android's rotation settings before saving or loading a snapshot. Check ADB and retry.") }
                    let previous = detachBridge(); await previous?.stop()
                    try checkOperation(token)
                }
                switch action {
                case .refresh: break
                case .save(let name): try await service.save(name: name)
                case .load(let name): try await service.load(name: name)
                case .delete(let name): try await service.delete(name: name)
                }
                try checkOperation(token)
                if case .load = action {
                    let deadline = ProcessInfo.processInfo.systemUptime + 30
                    while true {
                        let remaining = deadline - ProcessInfo.processInfo.systemUptime
                        guard runtime?.process.isRunning == true, remaining > 0 else {
                            throw AppFailure("The snapshot loaded, but Android did not reconnect within 30 seconds. Check diagnostics and retry the display.")
                        }
                        let value = try? await adb.run(ADBService.shellArguments(for: ["getprop", "sys.boot_completed"]), timeout: min(remaining, 3)).text
                        try checkOperation(token)
                        if value?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { break }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                snapshots = try await service.list()
            } catch is CancellationError { return }
            catch let failure as EmulatorSnapshotError {
                operationError = failure.localizedDescription
                if case .unsupported = failure { unsupportedReason = failure.localizedDescription }
            }
            catch { operationError = error.localizedDescription }
            guard token == generation, runtime?.id == runtimeID else { return }
            // Only an explicit console capability failure disables snapshots.
            // A display reconnect cannot change this runtime's discovered limit.
            if let unsupportedReason {
                unsupportedSnapshots = (runtimeID, unsupportedReason)
            }
            if quiesce {
                if runtime?.process.isRunning == true {
                    reconnect(reason: "Reconnect after snapshot operation")
                    await reconnectTask?.value
                } else {
                    transition(.failed, "The emulator exited during the snapshot operation")
                    // Save/load paused the monitor. Resume its common exit
                    // handler after this task unwinds; calling cleanup here
                    // would self-await through stopResources -> snapshotTask.
                    beginMonitoring(token: token)
                }
            }
            guard token == generation else { return }
            snapshotBusy = false
            if logsRequested, state == .running, windowVisible { startLogs() }
            if let operationError { error = operationError; actionStatus = nil }
            else { actionStatus = action.completion }
            refreshDisplayedDiagnostics()
        }
    }
    private func cancelDeveloperActions() async {
        let pending = Array(developerActions.values)
        developerActions.removeAll()
        actionStatus = nil
        pending.forEach { $0.cancel() }
        for action in pending { await action.value }
    }
    private func presentDevicePanel(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { ($0.windowController as? DeviceWindowController)?.session === self }) {
            window.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }
    func startLogs() {
        logsRequested = true
        guard !snapshotBusy, logsTask == nil, state != .idle, state != .failed, state != .stopping else { return }
        let token = generation, request = UUID(); logsID = request
        let previousCleanup = Array(retiringLogs.values)
        logsTask = Task {
            for previous in previousCleanup { await previous.value }
            while !Task.isCancelled, token == generation, logsID == request {
                guard let adb, adbAvailable else {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    continue
                }
                let stream = LogcatStream(adb: adb); logStreamEnded = false
                let mailbox = LogMailbox()
                do {
                    try stream.start(onLines: { [weak self] lines in
                        guard mailbox.put(lines) else { return }
                        Task { @MainActor in
                            let batch = mailbox.take()
                            guard let self, self.generation == token, self.logsID == request, !self.logPaused else { return }
                            self.appendLogLines(batch)
                        }
                    }, onError: { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.generation == token, self.logsID == request else { return }
                            self.appendLogLines(["[Logcat] " + message])
                            self.logStreamEnded = true
                        }
                    })
                    while !Task.isCancelled, token == generation, logsID == request, !logStreamEnded {
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                } catch { if !Task.isCancelled { appendLogLines(["[Logcat] " + error.localizedDescription]) } }
                await stream.stop()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    func stopLogs(preservingRequest: Bool = false) {
        if !preservingRequest { logsRequested = false }
        if let pending = logsTask {
            let request = UUID()
            pending.cancel(); retiringLogs[request] = pending
            Task { await pending.value; retiringLogs[request] = nil }
        }
        logsTask = nil; logsID = nil
    }
    private func joinLogCleanup() async {
        let pending = Array(retiringLogs.values)
        for task in pending { await task.value }
    }
    private func appendLogLines(_ lines: [String]) {
        logPresentation.append(lines)
    }
    func filteredLogText(matching query: String) -> String { logPresentation.filteredText(matching: query) }
    func setDeveloperPanel(_ panel: DeveloperPanelKind?) {
        if panel == .logs { startLogs() }
        else { stopLogs() }
        setDiagnosticsVisible(panel == .diagnostics)
    }
    func setDiagnosticsVisible(_ visible: Bool) {
        guard diagnosticsVisible != visible else { return }
        diagnosticsVisible = visible
        refreshDisplayedDiagnostics()
    }
    private func refreshDisplayedDiagnostics() {
        guard diagnosticsVisible else { return }
        displayedDiagnostics = diagnostics
    }
    var diagnostics: String { currentDiagnostics + (lastRuntimeFailure?.diagnostics ?? "") }
    private var currentDiagnostics: String {
        let proxy = frames.inputLatency.statistics
        let median = proxy.medianMilliseconds.map { String(format: "%.1f ms", $0) } ?? "No samples"
        let p95 = proxy.p95Milliseconds.map { String(format: "%.1f ms", $0) } ?? "No samples"
        let snapshotLimit = snapshotUnsupportedReason.map { "Snapshot support: Unavailable for this runtime\n\($0)\n" } ?? ""
        return sessionDiagnostics + surfaceDiagnostics + snapshotLimit + "Runtime history file: \(runtimeLedger.url.path)\nHistory warning: \(historyWarning ?? "None")\nInput-to-next-frame proxy: median \(median), p95 \(p95), \(proxy.sampleCount) recent samples\nProxy scope: input dispatch to next subsequently received/submitted frame; does not establish Android response or physical display latency.\n"
    }
    private var surfaceDiagnostics: String {
        guard displayAttached, surfaceMetrics.streamID != nil else { return "" }
        let value = surfaceMetrics.counters
        let uptime = value.sampledAtUptime.map { String(format: "%.6f", $0) } ?? "Unavailable"
        let elapsed = value.elapsedSeconds.map { String(format: "%.6f", $0) } ?? "Unavailable"
        return "Surface stream: \(surfaceMetrics.streamID?.uuidString ?? "None")\nSurface sample uptime: \(uptime) s; elapsed since bridge start: \(elapsed) s\nSurface stream frames: \(surfaceMetrics.decodedFrames) decoded, \(surfaceMetrics.submittedFrames) submitted\nSurface counters since bridge start: \(value.ticks) ticks, \(value.enqueued) enqueued\nSurface timer gap: max \(String(format: "%.1f", value.maximumTickGapMilliseconds)) ms, \(value.delayedTickGaps) gaps >50 ms\nSurface callback work: max \(String(format: "%.1f", value.maximumWorkMilliseconds)) ms\nSurface skips: \(value.notReady) layer not ready, \(value.noFrame) no decoded frame\nSurface recovery: \(value.flushes) flushes, \(value.failedLayerTicks) failed-layer ticks\nSurface sample errors: \(value.formatErrors) format (last \(value.lastFormatError.map(String.init) ?? "none")), \(value.sampleErrors) sample (last \(value.lastSampleError.map(String.init) ?? "none"))\nSurface layer status: \(value.lastLayerStatus.rawValue); last error: \(value.lastLayerError ?? "None")\nSurface scope: cumulative for this bridge, sampled about once per second; compare matching stream IDs and uptime deltas. Counts do not measure physical presentation.\n"
    }
    private var sessionDiagnostics: String {
        "DroidDock diagnostics\nDate: \(Date())\nDevice: \(avd.name)\nState: \(state.rawValue)\nSDK: \(sdk.root.path)\nSerial: \(runtime?.serial ?? "—")\nOwned PID: \(runtime.map { String($0.process.processIdentifier) } ?? "—")\nSession journal: \(journal?.url.path ?? "Unavailable")\nRuntime log: \((runtime?.logURL ?? lastRuntimeLogURL)?.path ?? "—")\nADB: \(adbAvailable ? "Connected" : "Unavailable")\nConsole port: \(runtime.map { String($0.consolePort) } ?? "—")\nGPU mode: \(gpuMode)\n\(versions?.summary ?? "Versions not inspected yet")\nTransport: \(ScrcpyRuntimeAdapter.capabilities.summary)\nReceive FPS: \(Int(fps))\nSubmitted FPS: \(Int(submittedFPS))\nReceive-to-submit: \(String(format: "%.1f", receiveToSubmitMilliseconds)) ms\nEmulator CPU: \(resources?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? (runtime == nil ? "Not running" : "Sampling"))\nResident memory: \(resources.map { String($0.residentMemoryBytes / 1_048_576) + " MB" } ?? "Unavailable")\nFrames superseded before presentation: \(droppedFrames)\nReceive-to-decode: \(String(format: "%.1f", decodeMilliseconds)) ms\nError: \(error ?? "None")\n"
    }
}

struct AppFailure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }

enum SnapshotAction {
    case refresh, save(String), load(String), delete(String)
    var requiresConfirmation: Bool { if case .refresh = self { return false }; return true }
    var replacesRuntimeState: Bool {
        switch self { case .save, .load: return true; case .refresh, .delete: return false }
    }
    var progress: String {
        switch self {
        case .refresh: return "Reading snapshots…"
        case .save(let name): return "Saving snapshot \(name)…"
        case .load(let name): return "Loading snapshot \(name)…"
        case .delete(let name): return "Deleting snapshot \(name)…"
        }
    }
    var completion: String {
        switch self {
        case .refresh: return "Snapshots refreshed"
        case .save(let name): return "Snapshot saved: \(name)"
        case .load(let name): return "Snapshot loaded: \(name)"
        case .delete(let name): return "Snapshot deleted: \(name)"
        }
    }
}

private final class APKPanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        return url.pathExtension.lowercased() == "apk"
    }
    func panel(_ sender: Any, validate url: URL) throws {
        guard url.pathExtension.lowercased() == "apk" else { throw AppFailure("Choose an Android APK file.") }
    }
}

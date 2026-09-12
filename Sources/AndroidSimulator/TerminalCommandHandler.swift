import AppKit
import SimulatorKit

struct TerminalCommandFailure: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// URL delivery only wakes the app. The command itself must come from the
/// bounded, owner-only local mailbox written by the bundled terminal client.
@MainActor
final class TerminalCommandHandler {
    static let shared = TerminalCommandHandler(model: .shared)
    private let model: AppModel
    private let store: SimulatorCommandStore
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var mutatingDevices: Set<String> = []

    init(model: AppModel, store: SimulatorCommandStore = SimulatorCommandStore()) {
        self.model = model; self.store = store
    }

    func receive(_ urls: [URL]) {
        for url in urls {
            guard let id = SimulatorCommandStore.requestID(from: url), tasks[id] == nil else { continue }
            let request: SimulatorCommandRequest
            do { request = try store.consumeRequest(id: id) }
            catch { continue } // Arbitrary web links cannot create or execute commands.
            tasks[id] = Task {
                defer { tasks[id] = nil }
                let response = await execute(request)
                do { try store.writeResponse(response) }
                catch { NSLog("Could not write terminal command response: %@", error.localizedDescription) }
            }
        }
    }

    func execute(_ request: SimulatorCommandRequest) async -> SimulatorCommandResponse {
        let operation = Task { await executeAccepted(request) }
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: UInt64(max(0, min(600, request.remainingTime())) * 1_000_000_000)) }
            catch { return }
            operation.cancel()
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
    }

    private func executeAccepted(_ request: SimulatorCommandRequest) async -> SimulatorCommandResponse {
        do {
            try Task.checkCancellation()
            try request.validated()
            guard !model.isQuitting else { throw failure("quitting", "DroidDock is quitting. Try again after it exits.") }
            if request.action == .open, request.device == nil {
                model.showLibrary()
                NSApplication.shared.activate(ignoringOtherApps: true)
                return response(request, "Opened Device Library")
            }
            await model.refresh()
            while model.loading { try await pause(request) }
            try Task.checkCancellation()
            try request.validated()
            guard model.sdk != nil else { throw failure("sdk_unavailable", model.error ?? "Choose an Android SDK in the app's Settings.") }
            if request.action == .list || (request.action == .status && request.device == nil) {
                return response(request, "\(model.devices.count) virtual device(s)", devices: model.devices.map(summary))
            }
            let avd = try resolveDevice(request.device)
            if request.action == .status { return response(request, avd.displayName, devices: [summary(avd)]) }
            guard mutatingDevices.insert(avd.id).inserted else {
                throw failure("device_busy", "A terminal command is already running for \(avd.name). Wait for it to finish; the native controls remain available.")
            }
            defer { mutatingDevices.remove(avd.id) }
            switch request.action {
            case .boot, .open:
                if let previous = model.sessions[avd.id], previous.state == .stopping ||
                    (previous.sdk.root != model.sdk?.root && previous.state == .failed) {
                    await previous.stop()
                    try Task.checkCancellation()
                    try request.validated()
                }
                if let external = model.externalSerial(for: avd) {
                    throw failure("externally_managed", "\(avd.name) is managed by another app (\(external)). Stop it there before starting it in DroidDock.")
                }
                model.launch(avd)
                NSApplication.shared.activate(ignoringOtherApps: true)
                if model.pendingLaunch?.avd.id == avd.id {
                    throw failure("confirmation_required", "Review the additional-device memory warning in DroidDock and confirm Start Device there.")
                }
                guard let session = model.sessions[avd.id] else {
                    throw failure("launch_failed", model.error ?? "The app could not create a device session.")
                }
                while session.state != .running || !session.adbAvailable {
                    if session.state == .failed { throw failure("launch_failed", session.error ?? session.status) }
                    if session.state == .idle || session.state == .stopping {
                        throw failure("launch_cancelled", "Device launch was stopped in the app.")
                    }
                    try await pause(request)
                }
                model.launch(avd)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return response(request, "\(avd.name) is ready for Android testing", devices: [summary(avd)])
            case .stop:
                let session = try ownedSession(avd)
                await session.stop()
                // Discovery preceded Stop and may still contain this runtime's
                // serial. Report the completed owned session, not that snapshot.
                let stopped = SimulatorCommandDevice(id: avd.id, name: avd.displayName,
                    state: session.state.rawValue, sdkPath: session.sdk.root.path)
                return response(request, "Stopped \(avd.name)", devices: [stopped])
            case .install:
                let session = try ownedSession(avd)
                guard let argument = request.argument else { throw failure("invalid_argument", "An APK path is required.") }
                let apk = URL(fileURLWithPath: argument)
                let message = try await session.runTerminalADBAction { adb in
                    try await adb.install(apk: apk)
                    return "Installed \(apk.lastPathComponent)"
                }
                return response(request, message, devices: [summary(avd)])
            case .openURL:
                let session = try ownedSession(avd)
                guard let argument = request.argument, SimulatorCommandRequest.isValidLaunchURL(argument) else {
                    throw failure("invalid_argument", "Provide an Android app link such as exp://, https://, or your development client's URL.")
                }
                let message = try await session.runTerminalADBAction { adb in
                    let result = try await adb.run(ADBService.shellArguments(for: ["am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", argument]), timeout: min(30, max(1, request.remainingTime())))
                    if result.text.contains("Error:") || result.stderrText.contains("Error:") {
                        throw RuntimeError.invalidArgument(result.text + result.stderrText)
                    }
                    return "Opened URL on \(avd.name)"
                }
                return response(request, message, devices: [summary(avd)])
            case .list, .status:
                return response(request, avd.displayName, devices: [summary(avd)])
            }
        } catch {
            let code: String
            if case SimulatorCommandError.expired = error { code = "expired" }
            else if error is CancellationError { code = request.remainingTime() <= 0 ? "timeout" : "cancelled" }
            else { code = (error as? TerminalCommandFailure)?.code ?? "command_failed" }
            return SimulatorCommandResponse(id: request.id, success: false, message: error.localizedDescription,
                devices: [], errorCode: code)
        }
    }

    private func pause(_ request: SimulatorCommandRequest) async throws {
        try request.validated()
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    private func resolveDevice(_ name: String?) throws -> AVD {
        guard !model.devices.isEmpty else { throw failure("no_devices", "Create an Android virtual device in Android Studio, then run droiddock list.") }
        if let name {
            if let exact = model.devices.first(where: { $0.id == name }) { return exact }
            let matches = model.devices.filter { $0.displayName == name }
            guard matches.count == 1, let match = matches.first else {
                throw failure("device_not_found", "No unique virtual device matches \(name). Run droiddock list and use its device ID.")
            }
            return match
        }
        return model.devices.first(where: { $0.id == model.selectedDevice }) ?? model.devices[0]
    }
    private func ownedSession(_ avd: AVD) throws -> SessionController {
        guard let session = model.sessions[avd.id], session.runtime != nil else {
            throw failure("not_owned", "\(avd.name) is not running in this app. Start it with droiddock boot \(avd.name).")
        }
        return session
    }
    private func summary(_ avd: AVD) -> SimulatorCommandDevice {
        let session = model.sessions[avd.id]
        let external = model.externalDevices.first { $0.avdName == avd.name && $0.serial != session?.runtime?.serial }
        return SimulatorCommandDevice(id: avd.id, name: avd.displayName,
            state: external != nil && session?.runtime == nil ? "external" : (session?.state.rawValue ?? "idle"),
            serial: session?.runtime?.serial ?? external?.serial, pid: session?.runtime?.process.processIdentifier,
            sdkPath: session?.sdk.root.path ?? model.sdk?.root.path, isOwned: session?.runtime != nil)
    }
    private func response(_ request: SimulatorCommandRequest, _ message: String,
                          devices: [SimulatorCommandDevice] = []) -> SimulatorCommandResponse {
        SimulatorCommandResponse(id: request.id, success: true, message: message, devices: devices)
    }
    private func failure(_ code: String, _ message: String) -> TerminalCommandFailure {
        TerminalCommandFailure(code: code, message: message)
    }
}

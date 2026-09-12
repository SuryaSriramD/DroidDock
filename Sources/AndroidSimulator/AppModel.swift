import AppKit
import SwiftUI
import Combine
import SimulatorKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let runtimeLedger: RuntimeLedger
    @Published var devices: [AVD] = []
    @Published var sdk: SDKInstallation?
    @Published var externalDevices: [ADBDevice] = []
    @Published var selectedDevice: String?
    @Published var loading = false
    @Published private(set) var isQuitting = false
    @Published var error: String?
    @Published var sessions: [String: SessionController] = [:]
    @Published var captureDirectory = UserDefaults.standard.string(forKey: "captureDirectory") ?? ""
    @Published var sdkPath = UserDefaults.standard.string(forKey: "sdkPath") ?? ""
    @Published var stopOnClose = UserDefaults.standard.bool(forKey: "stopOnClose")
    @Published var stopOnQuit = UserDefaults.standard.object(forKey: "stopOnQuit") as? Bool ?? true
    @Published var gpuMode = UserDefaults.standard.string(forKey: "gpuMode") ?? "host"
    @Published var pendingLaunch: DeviceLaunchRequest?
    @Published private(set) var priorRuntimes: [RuntimeLedger.Match] = []
    @Published private(set) var runtimeHistoryWarning: String?
    @Published private(set) var canResetRuntimeHistory = false
    private var refreshRequested = false
    init(runtimeLedger: RuntimeLedger = RuntimeLedger()) { self.runtimeLedger = runtimeLedger }
    private var libraryWindow: NSWindow?
    private var windows: [String: DeviceWindowController] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    func showLibrary() {
        guard !isQuitting else { return }
        if let window = NSApplication.shared.windows.first(where: { $0.title == "DroidDock" }) ?? libraryWindow {
            window.makeKeyAndOrderFront(nil); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DroidDock"; window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false; window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(rootView: LibraryView().environmentObject(self))
        window.setFrameAutosaveName("DeviceLibrary")
        if !window.setFrameUsingName("DeviceLibrary") { window.center() }
        libraryWindow = window; window.makeKeyAndOrderFront(nil)
    }
    func refresh() async {
        guard !isQuitting else { return }
        if loading { refreshRequested = true; return }
        loading = true; defer { loading = false }
        repeat {
            refreshRequested = false
            let requestedPath = sdkPath
            do {
                let resolved = try SDKLocator.resolve(explicitPath: requestedPath.isEmpty ? nil : requestedPath)
                let found = try await AVDRepository.discover(sdk: resolved)
                try Task.checkCancellation()
                let discovered = (try? await ADBService.devices(sdk: resolved)) ?? []
                try Task.checkCancellation()
                var previous: [RuntimeLedger.Match] = []
                var historyError: String?
                var resetAvailable = false
                do {
                    let owned = Set(sessions.values.compactMap { $0.runtime?.id })
                    previous = try await runtimeLedger.inspect(discovered: discovered, sdk: resolved, excludingRuntimeIDs: owned)
                } catch {
                    historyError = error.localizedDescription
                    if case RuntimeLedger.Error.corruptLedger = error { resetAvailable = true }
                }
                try Task.checkCancellation()
                guard !isQuitting else { return }
                guard requestedPath == sdkPath else { refreshRequested = true; continue }
                sdk = resolved; devices = found; externalDevices = discovered; priorRuntimes = previous
                error = nil; runtimeHistoryWarning = historyError; canResetRuntimeHistory = resetAvailable
                if selectedDevice == nil || !devices.contains(where: { $0.id == selectedDevice }) {
                    selectedDevice = devices.first(where: { $0.id == UserDefaults.standard.string(forKey: "lastDevice") })?.id ?? devices.first?.id
                }
            } catch is CancellationError {
                return
            } catch {
                guard !isQuitting else { return }
                guard requestedPath == sdkPath else { refreshRequested = true; continue }
                sdk = nil; devices = []; externalDevices = []; priorRuntimes = []
                runtimeHistoryWarning = nil; canResetRuntimeHistory = false; self.error = error.localizedDescription
            }
        } while refreshRequested
    }
    func priorRuntime(for avd: AVD) -> RuntimeLedger.Match? {
        guard sessions[avd.id]?.runtime?.process.isRunning != true else { return nil }
        return priorRuntimes.first { $0.avdName == avd.name }
    }
    func resetRuntimeHistory() {
        guard canResetRuntimeHistory, !isQuitting else { return }
        Task {
            do { try await runtimeLedger.resetCorruptLedger(); await refresh() }
            catch { runtimeHistoryWarning = error.localizedDescription }
        }
    }
    func externalSerial(for avd: AVD) -> String? {
        // A previously owned session may have a stale discovery entry after stop.
        // The process manager performs fresh discovery before every real launch.
        guard sessions[avd.id] == nil else { return nil }
        let owned = Set(sessions.values.compactMap { $0.runtime?.serial })
        return externalDevices.first { $0.avdName == avd.name && !owned.contains($0.serial) }?.serial
    }
    func launch(_ avd: AVD, coldBoot: Bool = false, wipeData: Bool = false, resourcesConfirmed: Bool = false) {
        guard !isQuitting else { return }
        guard let sdk else { return }
        if let external = externalSerial(for: avd) { error = "\(avd.displayName) is already managed outside this app (\(external)). Stop it in its owning application before starting it here."; return }
        if let previous = sessions[avd.id], previous.state == .stopping {
            Task { await previous.stop(); launch(avd, coldBoot: coldBoot, wipeData: wipeData, resourcesConfirmed: resourcesConfirmed) }; return
        }
        let creatingRuntime = sessions[avd.id].map { !$0.isActive && $0.runtime?.process.isRunning != true } ?? true
        if creatingRuntime, !resourcesConfirmed {
            let others = sessions.values.filter { $0.avd.id != avd.id && ($0.isActive || $0.runtime?.process.isRunning == true) }
            let samples = others.compactMap { $0.resources?.residentMemoryBytes }
            if let warning = SessionResourcePolicy.warning(newDevice: avd, existingDevices: others.map(\.avd),
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                    knownResidentBytes: samples.isEmpty ? nil : samples.reduce(0, +)) {
                pendingLaunch = DeviceLaunchRequest(avd: avd, coldBoot: coldBoot, wipeData: wipeData, warning: warning)
                showLibrary(); return
            }
        }
        if let previous = sessions[avd.id], previous.sdk.root != sdk.root, previous.state == .stopping || previous.state == .failed {
            Task { await previous.stop(); launch(avd, coldBoot: coldBoot, wipeData: wipeData, resourcesConfirmed: resourcesConfirmed) }; return
        }
        if let previous = sessions[avd.id], previous.sdk.root != sdk.root, previous.state == .idle {
            windows[avd.id]?.close(); windows.removeValue(forKey: avd.id)
            sessions.removeValue(forKey: avd.id); subscriptions.removeValue(forKey: avd.id)
        }
        let session = sessions[avd.id] ?? SessionController(avd: avd, sdk: sdk)
        sessions[avd.id] = session
        if subscriptions[avd.id] == nil {
            // Library badges and prior-runtime labels depend on lifecycle and
            // identity, not every diagnostics/resource or log update.
            subscriptions[avd.id] = session.$state.removeDuplicates().dropFirst().map { _ in () }
                .merge(with: session.$runtime.map { $0?.id }.removeDuplicates().dropFirst().map { _ in () })
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
        session.setWindowVisible(true)
        UserDefaults.standard.set(avd.id, forKey: "lastDevice")
        if let window = windows[avd.id] { window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil) }
        else {
            let controller = DeviceWindowController(session: session, model: self)
            windows[avd.id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
        if coldBoot || wipeData, session.state != .idle { Task { await session.restart(coldBoot: coldBoot, wipeData: wipeData) } }
        else if session.state == .idle || session.state == .failed { session.start(coldBoot: coldBoot, wipeData: wipeData) }
    }
    func windowClosed(_ id: String) {
        windows.removeValue(forKey: id)
        if let session = sessions[id] { if stopOnClose { Task { await session.stop() } } else { session.setWindowVisible(false) } }
    }
    func chooseSDK() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Use SDK"; panel.message = "Select the Android SDK folder containing emulator and platform-tools."
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.sdkPath = url.path; self?.saveSettings(); await self?.refresh() }
        }
    }
    func chooseCaptureFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Use Capture Folder"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.captureDirectory = url.path; self?.saveSettings() }
        }
    }
    func saveSettings() {
        UserDefaults.standard.set(captureDirectory, forKey: "captureDirectory")
        UserDefaults.standard.set(gpuMode, forKey: "gpuMode")
        UserDefaults.standard.set(sdkPath, forKey: "sdkPath")
        UserDefaults.standard.set(stopOnClose, forKey: "stopOnClose")
        UserDefaults.standard.set(stopOnQuit, forKey: "stopOnQuit")
    }
    func shutdown() async { isQuitting = true; for session in sessions.values { if stopOnQuit { await session.stop() } else { await session.leaveRunningForQuit() } } }
}

struct DeviceLaunchRequest {
    let avd: AVD
    let coldBoot: Bool
    let wipeData: Bool
    let warning: String
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        TerminalCommandHandler.shared.receive(urls)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { @MainActor in await Task.yield(); AppModel.shared.showLibrary() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.showLibrary() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.sessions.values.contains(where: { $0.runtime != nil || $0.isActive || $0.state == .stopping || $0.hasPendingWork }) else { return .terminateNow }
        Task { @MainActor in await AppModel.shared.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

import AppKit
import SwiftUI
import Combine
import SimulatorKit

struct DeviceStopRequest {
    let avd: AVD
    let session: SessionController
    let generation: Int
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel(terminalSetup: TerminalSetupModel())
    let terminalSetup: TerminalSetupModel?
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
    @Published var showingAndroidSetup = false
    @Published var editingConfiguration: AVDConfigurationEditRequest?
    @Published private(set) var isSavingConfiguration = false
    @Published private(set) var isDeletingDevice = false
    @Published private(set) var configurationError: String?
    let androidSetup = AndroidSetupModel()
    // Derived from discovery so this survives relaunches and changes when the
    // managed runtime or its devices are removed. The setup sheet is transient.
    var isManagedAndroidReady: Bool { sdk?.avdHome != nil && !devices.isEmpty }
    @Published private(set) var priorRuntimes: [RuntimeLedger.Match] = []
    @Published private(set) var runtimeHistoryWarning: String?
    @Published private(set) var canResetRuntimeHistory = false
    private var refreshRequested = false
    private let configurationDeviceLookup: @MainActor (SDKInstallation) async throws -> [ADBDevice]
    private let configurationDeletion: @MainActor (AVDDeletionPlan) throws -> Void
    private var configurationMutation: AVD?
    private var configurationDeviceQuery: Task<[ADBDevice], Error>?
    private var terminalSetupSubscription: AnyCancellable?
    private var sessionLaunchTokens: [String: UUID] = [:]
    init(runtimeLedger: RuntimeLedger = RuntimeLedger(),
         configurationDeviceLookup: @escaping @MainActor (SDKInstallation) async throws -> [ADBDevice] = { try await ADBService.devices(sdk: $0) },
         configurationDeletion: @escaping @MainActor (AVDDeletionPlan) throws -> Void = { try AVDDeletionStore.delete($0) },
         terminalSetup: TerminalSetupModel? = nil) {
        self.runtimeLedger = runtimeLedger
        self.configurationDeviceLookup = configurationDeviceLookup
        self.configurationDeletion = configurationDeletion
        self.terminalSetup = terminalSetup
        terminalSetupSubscription = terminalSetup?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
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
                runtimeHistoryWarning = nil; canResetRuntimeHistory = false
                if case RuntimeError.sdkNotFound = error { self.error = nil }
                else { self.error = error.localizedDescription }
            }
            await terminalSetup?.configure(sdk: sdk)
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
        guard !deviceConfigurationBusy(avd) else {
            error = "Finish editing or deleting \(avd.displayName) before starting it."
            return
        }
        guard let sdk else { return }
        do { try prepareSessionForLaunch(avd) }
        catch { self.error = error.localizedDescription; return }
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
        let session: SessionController
        if let existing = sessions[avd.id] { session = existing }
        else {
            let token = UUID()
            sessionLaunchTokens[avd.id] = token
            session = SessionController(avd: avd, sdk: sdk, isQuitting: { [weak self] in
                guard let self else { return true }
                return self.isQuitting || self.deviceConfigurationBusy(avd) || self.sessionLaunchTokens[avd.id] != token
            })
        }
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
    func librarySession(for avd: AVD) -> SessionController? {
        guard let session = sessions[avd.id], let sdk,
              let current = devices.first(where: { $0.id == avd.id }),
              session.sdk.root.standardizedFileURL.resolvingSymlinksInPath() == sdk.root.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        let configuration = avd.configURL?.standardizedFileURL.resolvingSymlinksInPath()
        guard current.configURL?.standardizedFileURL.resolvingSymlinksInPath() == configuration,
              session.avd.configURL?.standardizedFileURL.resolvingSymlinksInPath() == configuration else { return nil }
        return session
    }
    /// A name can identify different phones after switching SDKs or changing an
    /// AVD index. Never reopen, restart, or wipe that older controller by name.
    func prepareSessionForLaunch(_ avd: AVD) throws {
        guard sdk != nil, let current = devices.first(where: { $0.id == avd.id }),
              current.configURL?.standardizedFileURL.resolvingSymlinksInPath() == avd.configURL?.standardizedFileURL.resolvingSymlinksInPath() else {
            throw AppFailure("The selected SDK or phone changed. Refresh the library and choose the phone again.")
        }
        guard let previous = sessions[avd.id], librarySession(for: avd) !== previous else { return }
        guard previous.state == .idle, !previous.hasPendingWork, previous.runtime?.process.isRunning != true else {
            throw AppFailure("A different phone named \(avd.name) still has a session in another SDK or configuration. Select its original SDK and stop that session, or stop it in its existing device window, before starting this phone.")
        }
        retireSession(avd.id)
    }
    func stopRequest(for avd: AVD) -> DeviceStopRequest? {
        guard !isQuitting, let session = librarySession(for: avd), session.state != .stopping,
              session.isActive || session.runtime?.process.isRunning == true || session.hasPendingWork else { return nil }
        return DeviceStopRequest(avd: avd, session: session, generation: session.lifecycleGeneration)
    }
    func stopDevice(_ request: DeviceStopRequest) async {
        guard !isQuitting else { return }
        guard let session = librarySession(for: request.avd), session === request.session else {
            error = "The phone session changed. Choose Stop Device again for the phone you want to stop."
            return
        }
        if session.state == .stopping { return }
        guard session.lifecycleGeneration == request.generation else {
            error = "The phone restarted while confirmation was open. Choose Stop Device again to stop the new session."
            return
        }
        await session.stop()
        // Editing/deletion also checks ADB discovery; discard its pre-stop
        // snapshot only after the controller has joined its shutdown work.
        await refresh()
    }
    func deviceConfigurationBusy(_ avd: AVD) -> Bool {
        [editingConfiguration?.avd, configurationMutation].compactMap { $0 }.contains { Self.sameDevice($0, avd) }
    }

    func presentAVDConfiguration(_ avd: AVD) {
        guard !isQuitting else { return }
        guard !loading, !isSavingConfiguration, !isDeletingDevice, editingConfiguration == nil else { return }
        do {
            guard let sdk else { throw AppFailure("Connect an Android SDK before editing a phone.") }
            try requireConfigurationContext(avd, sdk: sdk, requestedPath: sdkPath)
            try requireStoppedDevice(avd)
            try requireNoExternalRuntime(avd, discovered: externalDevices)
            let document = try AVDConfigurationStore.load(avd: avd)
            configurationError = nil
            editingConfiguration = AVDConfigurationEditRequest(avd: avd, document: document, sdk: sdk, requestedSDKPath: sdkPath)
        } catch { self.error = error.localizedDescription }
    }

    func saveAVDConfiguration(_ configuration: AVDConfiguration) async {
        guard let request = editingConfiguration, !isSavingConfiguration, !isDeletingDevice else { return }
        if let message = configuration.validationError { configurationError = message; return }
        isSavingConfiguration = true; configurationMutation = request.avd; configurationError = nil
        defer { isSavingConfiguration = false; configurationMutation = nil }
        do {
            try requireConfigurationContext(request.avd, sdk: request.sdk, requestedPath: request.requestedSDKPath)
            try requireStoppedDevice(request.avd)
            let discovered = try await lookupConfigurationDevices(sdk: request.sdk)
            try Task.checkCancellation()
            guard editingConfiguration?.id == request.id else { throw AppFailure("The configuration editor was closed. Open it again to save changes.") }
            try requireConfigurationContext(request.avd, sdk: request.sdk, requestedPath: request.requestedSDKPath)
            try requireStoppedDevice(request.avd)
            try requireNoExternalRuntime(request.avd, discovered: discovered)
            // No suspension between the final runtime checks and the store's
            // own file-identity/lock checks and atomic configuration replacement.
            try AVDConfigurationStore.save(configuration, document: request.document)
            retireStoppedSessions(for: request.avd)
            editingConfiguration = nil
            await refresh()
        } catch is CancellationError { }
        catch { configurationError = error.localizedDescription }
    }

    /// Called only after the product UI confirms deleting this exact phone.
    func deleteAVD(_ avd: AVD) async {
        guard !isSavingConfiguration, !isDeletingDevice, editingConfiguration == nil else {
            error = "Finish editing a phone before deleting one."
            return
        }
        isDeletingDevice = true; configurationMutation = avd; error = nil
        defer { isDeletingDevice = false; configurationMutation = nil }
        do {
            guard let sdk else { throw AppFailure("Connect an Android SDK before deleting a phone.") }
            let requestedPath = sdkPath
            try requireConfigurationContext(avd, sdk: sdk, requestedPath: requestedPath)
            try requireStoppedDevice(avd)
            let plan = try AVDDeletionStore.prepare(avd: avd, sdk: sdk)
            let discovered = try await lookupConfigurationDevices(sdk: sdk)
            try Task.checkCancellation()
            try requireConfigurationContext(avd, sdk: sdk, requestedPath: requestedPath)
            try requireStoppedDevice(avd)
            try requireNoExternalRuntime(avd, discovered: discovered)
            try configurationDeletion(plan)
            retireStoppedSessions(for: avd)
            if pendingLaunch?.avd.id == avd.id { pendingLaunch = nil }
            if selectedDevice == avd.id { selectedDevice = nil }
            await refresh()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func lookupConfigurationDevices(sdk: SDKInstallation) async throws -> [ADBDevice] {
        let query = Task { try await configurationDeviceLookup(sdk) }
        configurationDeviceQuery = query
        defer { configurationDeviceQuery = nil }
        return try await withTaskCancellationHandler { try await query.value } onCancel: { query.cancel() }
    }

    private func requireConfigurationContext(_ avd: AVD, sdk: SDKInstallation, requestedPath: String) throws {
        guard !isQuitting else { throw AppFailure("DroidDock is quitting. The phone was not changed.") }
        guard self.sdk == sdk, sdkPath == requestedPath,
              let current = devices.first(where: { $0.id == avd.id }),
              current.configURL?.standardizedFileURL.resolvingSymlinksInPath() == avd.configURL?.standardizedFileURL.resolvingSymlinksInPath() else {
            throw AppFailure("The selected SDK or phone changed. Refresh the library and open the phone again.")
        }
    }

    private func requireStoppedDevice(_ avd: AVD) throws {
        guard pendingLaunch.map({ Self.sameDevice($0.avd, avd) }) != true else {
            throw AppFailure("Cancel the pending start for \(avd.displayName) before changing it.")
        }
        guard !sessions.values.contains(where: { session in
            Self.sameDevice(session.avd, avd) &&
                (session.isActive || session.state == .stopping || session.hasPendingWork || session.runtime?.process.isRunning == true)
        }) else {
            throw AppFailure("Stop \(avd.displayName) and wait for it to finish before changing its configuration or deleting it.")
        }
    }

    private func requireNoExternalRuntime(_ avd: AVD, discovered: [ADBDevice]) throws {
        if discovered.contains(where: { device in
            device.avdName == avd.name || devices.contains(where: { $0.name == device.avdName && Self.sameDevice($0, avd) })
        }) {
            throw AppFailure("\(avd.displayName) is running. Stop it in the application that launched it before changing it.")
        }
        if discovered.contains(where: { $0.serial.hasPrefix("emulator-") && $0.avdName == nil }) {
            throw AppFailure("An Android emulator could not be identified. Stop it or restore its ADB connection before changing this phone.")
        }
    }

    private static func sameDevice(_ lhs: AVD, _ rhs: AVD) -> Bool {
        if lhs.id == rhs.id { return true }
        guard let left = lhs.configURL, let right = rhs.configURL else { return false }
        return left.standardizedFileURL.resolvingSymlinksInPath() == right.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func retireStoppedSessions(for avd: AVD) {
        let ids = sessions.filter { Self.sameDevice($0.value.avd, avd) }.map(\.key)
        for id in ids { retireSession(id) }
    }
    private func retireSession(_ id: String) {
        // Remove ownership before closing a stopped window so its delegate
        // cannot schedule Stop or keep immutable pre-edit AVD metadata alive.
        sessions.removeValue(forKey: id)
        sessionLaunchTokens.removeValue(forKey: id)
        subscriptions.removeValue(forKey: id)?.cancel()
        windows.removeValue(forKey: id)?.close()
    }
    func chooseSDK() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Use SDK"; panel.message = "Select the Android SDK folder containing emulator and platform-tools."
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.sdkPath = url.path; self?.saveSettings(); await self?.refresh() }
        }
    }
    func presentAndroidSetup() {
        guard !isQuitting, !loading, terminalSetup?.isPresented != true, !isManagedAndroidReady, !androidSetup.isBusy else { return }
        androidSetup.beginPresentation(loadCatalog: false)
        showLibrary()
        showingAndroidSetup = true
    }
    func presentAndroidVersions() {
        guard !isQuitting, !loading, terminalSetup?.isPresented != true, !androidSetup.isBusy else { return }
        androidSetup.beginPresentation(loadCatalog: true)
        showLibrary()
        showingAndroidSetup = true
    }
    var canPresentTerminalSetup: Bool {
        !isQuitting && !loading && !showingAndroidSetup && editingConfiguration == nil &&
            !AppUpdateModel.shared.showingUpdateSheet
    }
    var canPresentAppUpdates: Bool {
        !isQuitting && !showingAndroidSetup && editingConfiguration == nil && terminalSetup?.isPresented != true
    }
    func presentTerminalSetup() {
        guard canPresentTerminalSetup else { return }
        showLibrary()
        terminalSetup?.presentSetup()
    }
    func presentAppUpdates() {
        guard canPresentAppUpdates else { return }
        showLibrary()
        AppUpdateModel.shared.checkForUpdates()
    }
    func useManagedSDK(_ root: URL, deviceName: String? = nil) {
        guard !isQuitting else { return }
        sdkPath = root.path
        saveSettings()
        Task {
            await refresh()
            let name = deviceName ?? ManagedAndroidRuntime.deviceName
            if devices.contains(where: { $0.name == name }) {
                selectedDevice = name
            }
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
    func shutdown() async {
        isQuitting = true
        configurationDeviceQuery?.cancel()
        _ = await configurationDeviceQuery?.result
        await androidSetup.cancel()
        await terminalSetup?.waitForSetup()
        for session in sessions.values { if stopOnQuit { await session.stop() } else { await session.leaveRunningForQuit() } }
    }
}

struct AVDConfigurationEditRequest: Identifiable {
    let id = UUID()
    let avd: AVD
    let document: AVDConfigurationDocument
    let sdk: SDKInstallation
    let requestedSDKPath: String
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
        guard AppModel.shared.terminalSetup?.isWorking == true || AppModel.shared.androidSetup.isBusy || AppModel.shared.isSavingConfiguration || AppModel.shared.isDeletingDevice || AppModel.shared.sessions.values.contains(where: { $0.runtime != nil || $0.isActive || $0.state == .stopping || $0.hasPendingWork }) else { return .terminateNow }
        Task { @MainActor in await AppModel.shared.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

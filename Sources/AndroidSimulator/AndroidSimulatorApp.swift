import SwiftUI
import AppKit
import SimulatorKit

@main
struct AndroidSimulatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var appUpdates = AppUpdateModel.shared
    var body: some Scene {
        WindowGroup("DroidDock") { LibraryView().environmentObject(model).frame(minWidth: 900, minHeight: 620) }
            .defaultSize(width: 1080, height: 740)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { model.presentAppUpdates() }.disabled(!model.canPresentAppUpdates)
                    Button("Terminal Setup…") { model.presentTerminalSetup() }.disabled(!model.canPresentTerminalSetup)
                }
                CommandGroup(after: .newItem) { Button("Refresh Devices") { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: [.command, .shift]) }
            }
        Settings { SettingsView().environmentObject(model).frame(width: 560) }
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var appUpdates = AppUpdateModel.shared
    @State private var coldBootDevice: AVD?
    @State private var wipeDevice: AVD?
    @State private var deleteDevice: AVD?
    @State private var stopDevice: DeviceStopRequest?
    @State private var confirmResetHistory = false
    var selected: AVD? { model.devices.first { $0.id == model.selectedDevice } }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 23)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) { Text("DroidDock").font(.headline); Text("YOUR DEVICE WORKSPACE").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 18).padding(.vertical, 28)
                Text("LIBRARY").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 10)
                List(selection: $model.selectedDevice) {
                    ForEach(model.devices) { avd in
                        HStack(spacing: 10) { Image(systemName: "iphone.gen3").font(.system(size: 23)).foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 4) { Text(avd.displayName).font(.system(size: 12, weight: .medium)); Text(avd.platformDescription).font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); if model.sessions[avd.id]?.isActive == true { Circle().fill(.green).frame(width: 6, height: 6) } }.padding(.vertical, 8).tag(avd.id)
                    }
                }.listStyle(.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Circle().fill(model.sdk == nil ? .orange : .green).frame(width: 6, height: 6); Text(model.sdk == nil ? "Android setup required" : model.sdk?.avdHome == nil ? "Android SDK connected" : "Android by DroidDock").font(.system(size: 11)) }
                    if !model.isManagedAndroidReady && !model.loading {
                        Button { model.presentAndroidSetup() } label: { Label("Set Up Android", systemImage: "arrow.down.circle").font(.system(size: 11)) }.buttonStyle(.plain)
                    } else if model.isManagedAndroidReady {
                        Button { model.presentAndroidVersions() } label: { Label("Android Versions…", systemImage: "arrow.down.circle").font(.system(size: 11)) }.buttonStyle(.plain).disabled(model.loading)
                    }
                    Button { model.chooseSDK() } label: { Label("SDK Settings", systemImage: "gearshape").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    if model.terminalSetup != nil {
                        Button { model.presentTerminalSetup() } label: { Label("Terminal Setup…", systemImage: "terminal").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!model.canPresentTerminalSetup)
                    }
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 290)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) { Text("Device Library").font(.system(size: 28, weight: .semibold)); Text("A little more native. A lot more focused.").foregroundStyle(.secondary).font(.system(size: 13)) }
                        Spacer()
                        if !model.devices.isEmpty {
                            Button("Add Phone…") { model.presentAndroidVersions() }.disabled(model.loading)
                        }
                        Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }.help("Refresh devices").disabled(model.loading)
                    }
                    if let error = model.error { HStack(alignment: .top, spacing: 10) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).font(.system(size: 12)).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)) }
                    if let warning = model.runtimeHistoryWarning {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Runtime history unavailable").font(.headline)
                            Text(warning).font(.caption).textSelection(.enabled)
                            if model.canResetRuntimeHistory { Button("Reset Session History…") { confirmResetHistory = true }.disabled(model.loading) }
                        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.loading && model.devices.isEmpty { ProgressView("Finding your devices…").frame(maxWidth: .infinity, minHeight: 320) }
                    else if let avd = selected { deviceCard(avd) }
                    else if model.devices.isEmpty { setupCard }
                    else {
                        VStack(spacing: 14) {
                            Image(systemName: "iphone.gen3").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text("Choose a device").font(.title2.weight(.semibold))
                            Text("Select a phone from your library to get started.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 320)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        feature("macwindow", "Made for your Mac", "Native windows, fullscreen, and room for your workflow.")
                        feature("bolt.horizontal", "Android, included", "Set up a phone here. Android Studio is optional.")
                        feature("lock.shield", "Your devices stay yours", "Local runtime. Explicit process ownership. No cloud account.")
                    }.padding(.top, 2)
                    Divider()
                    HStack { Text("\(model.devices.count) \(model.devices.count == 1 ? "device" : "devices") available"); Spacer(); Text("LOCAL WORKSPACE").font(.system(size: 9, weight: .medium, design: .monospaced)) }.font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(34)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.background {
            if let setup = model.terminalSetup {
                TerminalSetupPresentation(setup: setup) {
                    Task { if model.canPresentAppUpdates { await appUpdates.checkAutomaticallyIfNeeded() } }
                }
            }
        }.task {
            await model.refresh()
            if model.canPresentTerminalSetup {
                model.terminalSetup?.presentIfNeeded()
            }
            if model.canPresentAppUpdates { await appUpdates.checkAutomaticallyIfNeeded() }
        }
            .sheet(isPresented: $model.showingAndroidSetup, onDismiss: checkForDeferredUpdate) {
                AndroidSetupView(setup: model.androidSetup) { model.useManagedSDK($0, deviceName: model.androidSetup.installedDeviceName) }
            }
            .sheet(isPresented: $appUpdates.showingUpdateSheet) { AppUpdateView(model: appUpdates) }
            .sheet(item: $model.editingConfiguration, onDismiss: checkForDeferredUpdate) { request in
                AVDConfigurationView(request: request).environmentObject(model)
            }
            .alert("Stop \(stopDevice?.avd.displayName ?? "this phone")?", isPresented: Binding(get: { stopDevice != nil }, set: { if !$0 { stopDevice = nil } })) {
                Button("Cancel", role: .cancel) { stopDevice = nil }
                Button("Stop Device", role: .destructive) {
                    guard let request = stopDevice else { return }
                    stopDevice = nil
                    Task { await model.stopDevice(request) }
                }
            } message: {
                Text("This shuts down the phone and keeps its installed apps and data. You can start it again from the library.")
            }
            .alert("Delete \(deleteDevice?.displayName ?? "this phone")?", isPresented: Binding(get: { deleteDevice != nil }, set: { if !$0 { deleteDevice = nil } })) {
                Button("Cancel", role: .cancel) { deleteDevice = nil }
                Button("Move to Trash", role: .destructive) {
                    guard let avd = deleteDevice else { return }
                    deleteDevice = nil
                    Task { await model.deleteAVD(avd) }
                }
            } message: {
                Text("This moves the phone and its apps, settings, and data to the Trash. The Android runtime stays installed. Deleting your last phone makes Set Up Android available again.")
            }
            .alert("Cold boot this device?", isPresented: Binding(get: { coldBootDevice != nil }, set: { if !$0 { coldBootDevice = nil } })) {
                Button("Cancel", role: .cancel) { coldBootDevice = nil }
                Button("Cold Boot") { if let avd = coldBootDevice { model.launch(avd, coldBoot: true) }; coldBootDevice = nil }
            } message: { Text("Android will boot without loading its quick-boot snapshot. Your installed apps and device data are kept.") }
            .alert("Erase this device's data?", isPresented: Binding(get: { wipeDevice != nil }, set: { if !$0 { wipeDevice = nil } })) {
                Button("Cancel", role: .cancel) { wipeDevice = nil }
                Button("Erase and Start", role: .destructive) { if let avd = wipeDevice { model.launch(avd, wipeData: true) }; wipeDevice = nil }
            } message: { Text("This permanently removes installed apps, accounts, settings, and user data from \(wipeDevice?.displayName ?? "this device"), then starts Android from its initial state. This cannot be undone.") }
            .alert("Start another Android device?", isPresented: Binding(get: { model.pendingLaunch != nil }, set: { if !$0 { model.pendingLaunch = nil } })) {
                Button("Cancel", role: .cancel) { model.pendingLaunch = nil }
                Button("Start Device") {
                    guard let request = model.pendingLaunch else { return }
                    model.pendingLaunch = nil
                    model.launch(request.avd, coldBoot: request.coldBoot, wipeData: request.wipeData, resourcesConfirmed: true)
                }
            } message: { Text(model.pendingLaunch?.warning ?? "") }
            .alert("Reset damaged session history?", isPresented: $confirmResetHistory) {
                Button("Cancel", role: .cancel) { }
                Button("Reset History") { model.resetRuntimeHistory() }
            } message: { Text("This replaces damaged tracking metadata. Running emulators stay external, and their processes and Android data are unchanged.") }
    }
    func deviceCard(_ avd: AVD) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 36) {
                VStack(alignment: .leading, spacing: 18) {
                    Label(deviceStatus(avd), systemImage: "circle.fill").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(model.externalSerial(for: avd) != nil || model.librarySession(for: avd)?.state == .stopping ? Color.orange : Color.green)
                    Text(avd.displayName).font(.system(size: 32, weight: .semibold))
                    Text("Your Android device.\nRight at home on macOS.").font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
                    if let previous = model.priorRuntime(for: avd) {
                        Text(previous.disposition == .intentionallyLeftRunning
                             ? "Left running by an earlier app session (\(previous.serial)). Stop it using Android tooling, then refresh to start it here."
                             : "A matching emulator from a previous app session is still running (\(previous.serial)). The earlier session may have been interrupted. Stop it using Android tooling, then refresh.")
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    HStack(spacing: 10) {
                        Button { model.launch(avd) } label: { Label(model.sessions[avd.id]?.isActive == true ? "Open Device" : "Start Device", systemImage: "play.fill").padding(.horizontal, 10).padding(.vertical, 5) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.externalSerial(for: avd) != nil || model.librarySession(for: avd)?.state == .stopping)
                        if model.stopRequest(for: avd) != nil || model.librarySession(for: avd)?.state == .stopping {
                            Button { stopDevice = model.stopRequest(for: avd) } label: {
                                Label(model.librarySession(for: avd)?.state == .stopping ? "Stopping…" : "Stop Device", systemImage: "stop.fill")
                                    .padding(.vertical, 5)
                            }.controlSize(.large).disabled(model.librarySession(for: avd)?.state == .stopping)
                        }
                        Menu {
                            if model.stopRequest(for: avd) != nil || model.librarySession(for: avd)?.state == .stopping {
                                Button("Stop Device…", role: .destructive) { stopDevice = model.stopRequest(for: avd) }
                                    .disabled(model.librarySession(for: avd)?.state == .stopping)
                                Divider()
                            }
                            Button("Edit AVD Configuration…") { model.presentAVDConfiguration(avd) }
                                .disabled(configurationActionUnavailable(avd))
                            Divider()
                            Button("Cold Boot…") { coldBootDevice = avd }.disabled(model.externalSerial(for: avd) != nil || model.librarySession(for: avd)?.state == .stopping)
                            Button("Wipe Data…", role: .destructive) { wipeDevice = avd }.disabled(model.externalSerial(for: avd) != nil || model.librarySession(for: avd)?.state == .stopping)
                            Divider()
                            Button("Show Configuration in Finder") { if let url = avd.configURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.disabled(avd.configURL == nil)
                            Divider()
                            Button("Delete Phone…", role: .destructive) { deleteDevice = avd }
                                .disabled(configurationActionUnavailable(avd))
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).help("Device actions")
                    }.padding(.top, 8)
                    if model.isDeletingDevice {
                        ProgressView("Moving phone to Trash…").controlSize(.small)
                    } else if model.librarySession(for: avd)?.state == .stopping {
                        ProgressView("Stopping the phone…").controlSize(.small)
                    } else if phoneIsRunning(avd) {
                        Text("Stop the phone before editing its configuration or deleting it.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                phoneIllustration.frame(width: 150, height: 275).padding(.vertical, 8)
            }.padding(30)
            Divider()
            HStack(spacing: 0) {
                spec("ANDROID API", avd.apiLevel); spec("ARCHITECTURE", avd.architecture); spec("RESOLUTION", avd.resolution); spec("MEMORY", avd.memoryMB > 0 ? "\(avd.memoryMB) MB" : "Default")
            }.padding(.vertical, 22).padding(.horizontal, 26)
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08), lineWidth: 1))
    }
    private func deviceStatus(_ avd: AVD) -> String {
        if model.externalSerial(for: avd) != nil { return "EXTERNALLY MANAGED" }
        guard let session = model.librarySession(for: avd) else { return "READY FOR DEVELOPMENT" }
        switch session.state {
        case .stopping: return "STOPPING"
        case .starting, .booting, .connecting: return "STARTING"
        case .running, .reconnecting: return "RUNNING"
        case .failed where session.runtime?.process.isRunning == true: return "RUNNING · DISPLAY UNAVAILABLE"
        default: return "READY FOR DEVELOPMENT"
        }
    }
    private func phoneIsRunning(_ avd: AVD) -> Bool {
        if let session = model.sessions[avd.id], session.isActive || session.state == .stopping || session.runtime?.process.isRunning == true {
            return true
        }
        return model.externalSerial(for: avd) != nil || model.priorRuntime(for: avd) != nil
    }
    private func configurationActionUnavailable(_ avd: AVD) -> Bool {
        avd.configURL == nil || model.loading || model.deviceConfigurationBusy(avd) || phoneIsRunning(avd)
    }
    var phoneIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 27).fill(Color(white: 0.16)).shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 13)
            RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [Color(red: 0.73, green: 0.85, blue: 0.79), Color(red: 0.40, green: 0.65, blue: 0.57)], startPoint: .topLeading, endPoint: .bottomTrailing)).padding(5)
            VStack { Circle().fill(.black.opacity(0.7)).frame(width: 7, height: 7).padding(.top, 12); Spacer(); Image(systemName: "sparkle").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(.white.opacity(0.75)); Text("ANDROID").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(3).foregroundStyle(.white.opacity(0.8)); Spacer(); Capsule().fill(.white.opacity(0.8)).frame(width: 44, height: 3).padding(.bottom, 12) }
        }.accessibilityLabel("Decorative Android device illustration")
    }
    var setupCard: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.gen3").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Your first Android phone starts here").font(.title2.weight(.semibold))
            Text("DroidDock can download Android and create a phone for you. No Android Studio required.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Set Up Android") { model.presentAndroidSetup() }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("Use an Existing Android SDK…") { model.chooseSDK() }.font(.caption)
        }.frame(maxWidth: .infinity).padding(.vertical, 65).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
    private func checkForDeferredUpdate() {
        Task { if model.canPresentAppUpdates { await appUpdates.checkAutomaticallyIfNeeded() } }
    }
    func feature(_ icon: String, _ title: String, _ detail: String) -> some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).font(.system(size: 19)).foregroundStyle(.secondary); Text(title).font(.system(size: 12, weight: .semibold)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3) }.frame(maxWidth: .infinity, alignment: .leading) }
    func spec(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary); Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)) }.frame(maxWidth: .infinity, alignment: .leading) }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var appUpdates = AppUpdateModel.shared
    @State private var keyMappings = Dictionary(uniqueKeysWithValues: KeyboardMappings.functionKeys.map { ($0.keyCode, KeyboardMappings.action(for: $0.keyCode)) })
    @State private var copiedTerminalCommand = false
    @State private var copiedEnvironment = false
    var body: some View {
        Form {
            Section("Android") {
                if model.isManagedAndroidReady {
                    Label("Android is installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Your phone is ready in the Device Library.").font(.caption).foregroundStyle(.secondary)
                    Button("Android Versions…") { model.presentAndroidVersions() }.disabled(model.loading)
                } else {
                    Button("Set Up Android…") { model.presentAndroidSetup() }.disabled(model.loading)
                    Text("Download Android and create a phone inside DroidDock, or connect an existing SDK below. Android Studio is optional.").font(.caption).foregroundStyle(.secondary)
                }
                HStack { TextField("SDK path (automatic when blank)", text: $model.sdkPath); Button("Choose…") { model.chooseSDK() } }
            }
            Section("DroidDock updates") {
                Toggle("Automatically check for app updates", isOn: $appUpdates.automaticallyChecks)
                HStack {
                    Text("DroidDock \(appUpdates.installedVersion)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…") { model.presentAppUpdates() }.disabled(!model.canPresentAppUpdates)
                }
                Text("Checks when the app opens, at most once a day. Android versions are downloaded separately when you choose them.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Device lifecycle") { Toggle("Stop a device when its window closes", isOn: $model.stopOnClose); Toggle("Stop app-owned devices when quitting", isOn: $model.stopOnQuit); Text("Closing a window keeps Android running by default. Devices started outside this app are never stopped.").font(.caption).foregroundStyle(.secondary) }
            Section("Captures") { HStack { TextField("Screenshot and recording folder", text: $model.captureDirectory); Button("Choose…") { model.chooseCaptureFolder() } } }
            Section("Terminal") {
                if let setup = model.terminalSetup {
                    TerminalSetupStatusView(setup: setup) { model.presentTerminalSetup() }
                        .disabled(!model.canPresentTerminalSetup)
                }
                Text("Launch a device with droiddock boot, then press A in Expo. Use Shift+A to choose a device when several are available.").font(.caption).foregroundStyle(.secondary)
                if let sdk = model.sdk {
                    Button(copiedEnvironment ? "Android Environment Copied" : "Copy Android Environment") {
                        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                        let commands: String
                        if let setup = model.terminalSetup, case .ready = setup.state {
                            commands = ". " + quote(TerminalEnvironmentInstaller().environmentFile.path)
                        } else {
                            var lines = sdk.environmentOverrides.sorted { $0.key < $1.key }.map { "export \($0.key)=" + quote($0.value) }
                            lines.append("export PATH=\"$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH\"")
                            commands = lines.joined(separator: "\n")
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commands, forType: .string)
                        copiedEnvironment = true
                    }
                    Text("For a terminal that is already open, paste these commands to use this Android runtime immediately.").font(.caption).foregroundStyle(.secondary)
                }
                Button(copiedTerminalCommand ? "Install Command Copied" : "Copy Terminal Install Command") {
                    guard let installer = Bundle.main.url(forResource: "install-cli", withExtension: "sh") else { return }
                    let quoted = "'" + installer.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("/bin/bash " + quoted, forType: .string)
                    copiedTerminalCommand = true
                }.disabled(Bundle.main.url(forResource: "install-cli", withExtension: "sh") == nil)
                Text("Terminal Setup lets you review and apply the paths. The install command is also available for a custom command location.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Graphics") { Picker("Rendering", selection: $model.gpuMode) { Text("Host GPU (recommended)").tag("host"); Text("Software (compatibility)").tag("software"); Text("Emulator automatic").tag("auto") }; Text("Applies on the next device start. Software rendering may reduce frame rate.").font(.caption).foregroundStyle(.secondary) }
            Section("Keyboard") {
                Text("Click the device to focus. Type to send text; drag to swipe. Right-click sends Back. ⌘V sends your clipboard. System shortcuts stay on your Mac.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Function key mappings") {
                    ForEach(KeyboardMappings.functionKeys) { key in
                        Picker(key.title, selection: Binding(get: { keyMappings[key.keyCode] ?? .none }, set: { action in
                            keyMappings[key.keyCode] = action
                            KeyboardMappings.setAction(action, for: key.keyCode)
                        })) {
                            ForEach(KeyboardMappings.Action.allCases) { action in Text(action.title).tag(action) }
                        }
                    }
                    Text("Mappings apply immediately while the device has keyboard focus. Depending on your Mac's keyboard settings, hold Fn to send F1–F8. Modified shortcuts and text composition retain their normal behavior.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Save Settings") { model.saveSettings(); Task { await model.refresh() } }.buttonStyle(.borderedProminent) }
        }.formStyle(.grouped).padding(10)
    }
}

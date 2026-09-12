import SwiftUI
import AppKit
import SimulatorKit

@main
struct AndroidSimulatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        WindowGroup("DroidDock") { LibraryView().environmentObject(model).frame(minWidth: 900, minHeight: 620) }
            .defaultSize(width: 1080, height: 740)
            .commands {
                CommandGroup(after: .newItem) { Button("Refresh Devices") { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: [.command, .shift]) }
            }
        Settings { SettingsView().environmentObject(model).frame(width: 560) }
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var coldBootDevice: AVD?
    @State private var wipeDevice: AVD?
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
                        HStack(spacing: 10) { Image(systemName: "iphone.gen3").font(.system(size: 23)).foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 4) { Text(avd.displayName).font(.system(size: 12, weight: .medium)); Text("Android \(avd.apiLevel)").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); if model.sessions[avd.id]?.isActive == true { Circle().fill(.green).frame(width: 6, height: 6) } }.padding(.vertical, 8).tag(avd.id)
                    }
                }.listStyle(.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Circle().fill(model.sdk == nil ? .orange : .green).frame(width: 6, height: 6); Text(model.sdk == nil ? "SDK setup required" : "Android SDK connected").font(.system(size: 11)) }
                    Button { model.chooseSDK() } label: { Label("SDK Settings", systemImage: "gearshape").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 290)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) { Text("Device Library").font(.system(size: 28, weight: .semibold)); Text("A little more native. A lot more focused.").foregroundStyle(.secondary).font(.system(size: 13)) }
                        Spacer()
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
                    else { setupCard }
                    HStack(alignment: .top, spacing: 24) {
                        feature("macwindow", "Made for your Mac", "Native windows, fullscreen, and room for your workflow.")
                        feature("bolt.horizontal", "Android, underneath", "Your existing SDK and virtual devices, in one workspace.")
                        feature("lock.shield", "Your devices stay yours", "Local runtime. Explicit process ownership. No cloud account.")
                    }.padding(.top, 2)
                    Divider()
                    HStack { Text("\(model.devices.count) \(model.devices.count == 1 ? "device" : "devices") available"); Spacer(); Text("LOCAL WORKSPACE").font(.system(size: 9, weight: .medium, design: .monospaced)) }.font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(34)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.task { await model.refresh() }
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
                    Label(model.externalSerial(for: avd) != nil ? "EXTERNALLY MANAGED" : "READY FOR DEVELOPMENT", systemImage: "circle.fill").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(model.externalSerial(for: avd) != nil ? Color.orange : Color.green)
                    Text(avd.displayName).font(.system(size: 32, weight: .semibold))
                    Text("Your Android device.\nRight at home on macOS.").font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
                    if let previous = model.priorRuntime(for: avd) {
                        Text(previous.disposition == .intentionallyLeftRunning
                             ? "Left running by an earlier app session (\(previous.serial)). Stop it using Android tooling, then refresh to start it here."
                             : "A matching emulator from a previous app session is still running (\(previous.serial)). The earlier session may have been interrupted. Stop it using Android tooling, then refresh.")
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    HStack(spacing: 10) {
                        Button { model.launch(avd) } label: { Label(model.sessions[avd.id]?.isActive == true ? "Open Device" : "Start Device", systemImage: "play.fill").padding(.horizontal, 10).padding(.vertical, 5) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.externalSerial(for: avd) != nil)
                        Menu {
                            Button("Cold Boot…") { coldBootDevice = avd }.disabled(model.externalSerial(for: avd) != nil)
                            Button("Wipe Data…", role: .destructive) { wipeDevice = avd }.disabled(model.externalSerial(for: avd) != nil)
                            Divider()
                            Button("Show AVD Configuration") { if let url = avd.configURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.disabled(avd.configURL == nil)
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                    }.padding(.top, 8)
                }.frame(maxWidth: .infinity, alignment: .leading)
                phoneIllustration.frame(width: 150, height: 275).padding(.vertical, 8)
            }.padding(30)
            Divider()
            HStack(spacing: 0) {
                spec("ANDROID API", avd.apiLevel); spec("ARCHITECTURE", avd.architecture); spec("RESOLUTION", avd.resolution); spec("MEMORY", avd.memoryMB > 0 ? "\(avd.memoryMB) MB" : "Default")
            }.padding(.vertical, 22).padding(.horizontal, 26)
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08), lineWidth: 1))
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
            Image(systemName: model.sdk == nil ? "shippingbox" : "iphone.gen3").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(model.sdk == nil ? "Connect your Android SDK" : "Your first device starts here").font(.title2.weight(.semibold))
            Text(model.sdk == nil ? "Choose an existing SDK with Android Emulator and platform-tools installed." : "Create a virtual device in Android Studio’s Device Manager, then refresh this library.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button(model.sdk == nil ? "Choose SDK Folder" : "Refresh Devices") { if model.sdk == nil { model.chooseSDK() } else { Task { await model.refresh() } } }.buttonStyle(.borderedProminent)
            Link("Android SDK setup guide", destination: URL(string: "https://developer.android.com/studio/run/managing-avds")!).font(.caption)
        }.frame(maxWidth: .infinity).padding(.vertical, 65).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
    func feature(_ icon: String, _ title: String, _ detail: String) -> some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).font(.system(size: 19)).foregroundStyle(.secondary); Text(title).font(.system(size: 12, weight: .semibold)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3) }.frame(maxWidth: .infinity, alignment: .leading) }
    func spec(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary); Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)) }.frame(maxWidth: .infinity, alignment: .leading) }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyMappings = Dictionary(uniqueKeysWithValues: KeyboardMappings.functionKeys.map { ($0.keyCode, KeyboardMappings.action(for: $0.keyCode)) })
    @State private var copiedTerminalCommand = false
    var body: some View {
        Form {
            Section("Android SDK") { HStack { TextField("SDK path (automatic when blank)", text: $model.sdkPath); Button("Choose…") { model.chooseSDK() } }; Text("Use an existing SDK with emulator and platform-tools. Android components are not downloaded automatically.").font(.caption).foregroundStyle(.secondary) }
            Section("Device lifecycle") { Toggle("Stop a device when its window closes", isOn: $model.stopOnClose); Toggle("Stop app-owned devices when quitting", isOn: $model.stopOnQuit); Text("Closing a window keeps Android running by default. Devices started outside this app are never stopped.").font(.caption).foregroundStyle(.secondary) }
            Section("Captures") { HStack { TextField("Screenshot and recording folder", text: $model.captureDirectory); Button("Choose…") { model.chooseCaptureFolder() } } }
            Section("Terminal") {
                Text("Launch a device with droiddock boot, then press A in Expo. Use Shift+A to choose a device when several are available.").font(.caption).foregroundStyle(.secondary)
                Button(copiedTerminalCommand ? "Install Command Copied" : "Copy Terminal Install Command") {
                    guard let installer = Bundle.main.url(forResource: "install-cli", withExtension: "sh") else { return }
                    let quoted = "'" + installer.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("/bin/bash " + quoted, forType: .string)
                    copiedTerminalCommand = true
                }.disabled(Bundle.main.url(forResource: "install-cli", withExtension: "sh") == nil)
                Text("Paste the install command into Terminal after moving the app to Applications. It creates ~/.local/bin/droiddock and prints PATH instructions; shell settings stay under your control.").font(.caption).foregroundStyle(.secondary)
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

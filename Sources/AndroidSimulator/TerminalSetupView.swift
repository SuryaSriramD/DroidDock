import SwiftUI
import SimulatorKit

/// Hosted only by the library so Settings and the app menu open the same setup.
struct TerminalSetupPresentation: View {
    @ObservedObject var setup: TerminalSetupModel
    let onDismiss: () -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $setup.isPresented, onDismiss: onDismiss) {
                TerminalSetupView(setup: setup)
            }
    }
}

struct TerminalSetupView: View {
    @ObservedObject var setup: TerminalSetupModel

    private var ready: Bool {
        if case .ready = setup.state { return true }
        return false
    }

    private var paths: [String] {
        var folders: [String] = []
        if let sdk = setup.selectedSDK {
            folders += [sdk.root.appendingPathComponent("platform-tools").path, sdk.root.appendingPathComponent("emulator").path]
        }
        folders.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path)
        return folders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: ready ? "checkmark.circle.fill" : "terminal")
                    .font(.system(size: 32)).foregroundStyle(ready ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(ready ? "Terminal Is Ready" : "Set Up Terminal").font(.title2.weight(.semibold))
                    Text("Use your Android phone from Terminal and Expo.").foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let sdk = setup.selectedSDK {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Installed Android SDK", systemImage: "checkmark.circle").font(.headline)
                            path(sdk.root.path)
                            Text("ANDROID_HOME and ANDROID_SDK_ROOT will use this location.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Android setup is still needed", systemImage: "arrow.down.circle").font(.headline)
                        Text("You can add droiddock now. The adb and emulator commands will be added when you install Android or choose an SDK in DroidDock.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Folders added to PATH").font(.headline)
                        Text(setup.selectedSDK == nil ? "droiddock" : "adb · emulator · droiddock")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(paths, id: \.self) { folder in path(folder) }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                    if let avdHome = setup.selectedSDK?.avdHome {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Phone location · ANDROID_AVD_HOME").font(.caption.weight(.medium))
                            path(avdHome.path)
                        }
                    }

                    Text("Set Up Terminal adds these paths to your zsh and Bash startup settings. Your existing settings are kept, and changed files are backed up. Paths stay in sync when you choose another Android SDK in DroidDock.")
                        .font(.callout).foregroundStyle(.secondary)

                    switch setup.state {
                    case .ready:
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Open a new terminal to use these tools.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Try: droiddock list").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Text("For Expo, start the phone in DroidDock, run npx expo start in your project, then press A.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .settingUp:
                        ProgressView("Updating terminal settings…").controlSize(.small)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    case .requiresInstallation:
                        Label("Move DroidDock to Applications and open it there to set up terminal tools.", systemImage: "folder")
                            .font(.callout).foregroundStyle(.secondary)
                    case .idle:
                        Text("Changes apply to new terminal sessions after setup.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                if ready {
                    Button("Apply Again") { Task { await setup.applySetup() } }.disabled(!setup.canSetUp)
                } else {
                    Button("Later") { setup.dismissSetup() }.keyboardShortcut(.cancelAction).disabled(setup.isWorking)
                }
                Spacer()
                if ready {
                    Button("Done") { setup.dismissSetup() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(setup.isWorking ? "Setting Up…" : "Set Up Terminal") { Task { await setup.applySetup() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!setup.canSetUp)
                }
            }
        }.padding(28).frame(width: 580, height: 610)
            .interactiveDismissDisabled(setup.isWorking)
    }

    private func path(_ value: String) -> some View {
        Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

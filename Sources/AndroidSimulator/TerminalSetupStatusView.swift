import SwiftUI
import SimulatorKit

struct TerminalSetupStatusView: View {
    @ObservedObject var setup: TerminalSetupModel
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch setup.state {
            case .idle:
                Text("Add DroidDock and your Android tools to PATH for Terminal and Expo.")
                    .font(.caption).foregroundStyle(.secondary)
            case .settingUp:
                ProgressView("Setting up terminal tools…").controlSize(.small)
            case .ready(let hasAndroid):
                Label("Terminal tools are ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(hasAndroid
                     ? "Open a new terminal to use droiddock, adb, and emulator. Expo can find the selected Android runtime."
                     : "Open a new terminal to use droiddock. Android tools will be added after Android setup.")
                    .font(.caption).foregroundStyle(.secondary)
            case .requiresInstallation:
                Text("Move DroidDock to Applications and open Terminal Setup there.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Label("Terminal setup needs attention", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message).font(.caption).textSelection(.enabled)
            }
            Button("Terminal Setup…", action: openSetup).disabled(setup.isWorking)
        }
    }
}

import AppKit
import SwiftUI
import SimulatorKit

struct AppUpdateView: View {
    @ObservedObject var model: AppUpdateModel
    @State private var openingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DroidDock Updates").font(.title2.weight(.semibold))
                    Text("Installed version: \(model.installedVersion)").foregroundStyle(.secondary)
                }
            }
            switch model.state {
            case .idle:
                Text("Check GitHub for a newer stable release of DroidDock.")
            case .checking:
                ProgressView("Checking for updates…").controlSize(.small)
            case .available(let release):
                Text("DroidDock \(release.version) is available.").font(.headline)
                Text("Download the new release, quit DroidDock, and replace the app in Applications. Your Android phones and installed apps stay in your DroidDock data folder.")
                    .font(.callout).foregroundStyle(.secondary)
                if release.downloadURL == nil {
                    Text("The release does not yet include the standard Mac installer. Open its release page for details.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .upToDate:
                Label("You're up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("You have the latest stable DroidDock release.").font(.callout).foregroundStyle(.secondary)
            case .newerLocalBuild(let latest):
                Text("Your installed build is newer than the stable release.").font(.headline)
                Text("The latest stable release is \(latest). Keep this installation; no downgrade is needed.")
                    .font(.callout).foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .font(.callout).textSelection(.enabled)
            }
            if let openingError { Text(openingError).font(.caption).foregroundStyle(.orange) }
            Toggle("Automatically check for app updates", isOn: $model.automaticallyChecks)
            Text("Checks at most once a day when DroidDock opens. App downloads and installation start only when you choose them.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Close", role: .cancel) { model.showingUpdateSheet = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if case .available(let release) = model.state {
                    Button("View Release") { open(release.releaseURL) }
                    if let download = release.downloadURL {
                        Button("Download Update") { open(download) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Check Again") { openingError = nil; model.checkForUpdates() }
                        .disabled(model.isChecking).buttonStyle(.borderedProminent)
                }
            }
        }.padding(26).frame(width: 500)
    }

    private func open(_ url: URL) {
        openingError = NSWorkspace.shared.open(url) ? nil : "The browser could not open this link. Try again."
    }
}

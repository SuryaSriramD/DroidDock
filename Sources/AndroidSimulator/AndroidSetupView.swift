import SwiftUI
import SimulatorKit

struct AndroidSetupView: View {
    @ObservedObject var setup: AndroidSetupModel
    let finish: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cancelling = false
    @State private var presentationID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "iphone.gen3").font(.system(size: 32)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(setup.stage == .complete ? "Your phone is ready" : "Android Versions").font(.title2.weight(.semibold))
                    Text("Choose the Android versions you want on your Mac.").foregroundStyle(.secondary)
                }
            }
            if let error = setup.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            switch setup.stage {
            case .welcome, .loading:
                Text("Download Android directly from Google and create a phone inside DroidDock. Android Studio and Java are not required.")
                Text("Each version creates a separate phone. Your existing phones keep their apps and data. Downloads start only when you choose a version and accept its licenses.")
                    .font(.callout).foregroundStyle(.secondary)
                if setup.stage == .loading { ProgressView("Checking available versions…").controlSize(.small) }
            case .versions:
                Text("Add another Android version without replacing your existing phones.").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(setup.versions, id: \.runtime.id) { version in versionRow(version) }
                    }.padding(1)
                }.frame(height: 330)
                Text("Google APIs · Apple Silicon. Google Play Store is not included.")
                    .font(.caption).foregroundStyle(.secondary)
            case .review:
                if let plan = setup.plan, let availability = setup.reviewedAvailability {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(plan.runtime.title).font(.headline)
                        Text(setup.needsDownload ? "Download: \(size(availability.downloadBytes))" : "Android is already installed. No download needed.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Free space needed: \(size(availability.requiredDiskBytes)) for setup and phone data.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Creates a separate 1080 × 2400 phone. Existing phones stay as they are.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if setup.needsDownload {
                        Text("Review the licenses for these downloads:").font(.callout)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(Array(plan.licenses.enumerated()), id: \.offset) { _, license in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(license.id).font(.headline)
                                        Text(license.text).font(.system(size: 11)).textSelection(.enabled)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }.frame(height: 210).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        Toggle("I have read and accept the licenses above.", isOn: $setup.acceptedLicenses)
                    }
                }
            case .installing:
                Text("Creating your \(setup.plan?.runtime.title ?? "Android") phone").font(.headline)
                if let fraction = setup.progress.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
                Text(setup.progress.message).font(.callout).foregroundStyle(.secondary)
                Text("You can cancel setup and try again later.").font(.caption).foregroundStyle(.secondary)
            case .complete:
                Label(setup.plan?.runtime.title ?? "Android", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Choose Start Device in your library to open Android. Your apps and phone data are saved between launches.")
            }
            Divider()
            HStack {
                if setup.stage != .complete {
                    Button(cancelling ? "Cancelling…" : "Cancel", role: .cancel) {
                        cancelling = true
                        Task { await setup.cancel(); dismiss() }
                    }.disabled(cancelling)
                }
                if setup.stage == .review { Button("Back") { setup.backToVersions() }.disabled(cancelling) }
                Spacer()
                switch setup.stage {
                case .welcome:
                    Button(setup.error == nil ? "View Available Versions" : "Try Again") { setup.prepare() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(cancelling)
                case .versions:
                    Button("Refresh Versions") { setup.prepare() }.disabled(cancelling)
                case .review:
                    Button(setup.needsDownload ? "Agree & Download" : "Create Phone") { setup.startInstall() }
                        .buttonStyle(.borderedProminent).disabled(!setup.canInstall || cancelling)
                case .complete:
                    Button("Open Device Library") { openLibrary() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                default: EmptyView()
                }
            }
        }.padding(28).frame(width: 640)
            .interactiveDismissDisabled(setup.isBusy)
            .onAppear { presentationID = setup.presentationID }
            .onDisappear {
                guard let presentationID else { return }
                Task { await setup.cancel(presentationID: presentationID) }
            }
    }

    private func versionRow(_ version: AndroidInstallPlan) -> some View {
        let available = setup.availability[version.runtime.id]
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(version.runtime.title).font(.headline)
                    if version.runtime.id == setup.versions.first?.runtime.id {
                        Text("Latest stable").font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                if let available {
                    Text(available.installed ? (available.phoneExists ? "Installed · Phone available" : "Installed · Create a new phone") : "\(size(available.downloadBytes)) download")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let reason = setup.availabilityErrors[version.runtime.id] {
                    Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(available?.installed == true ? (available?.phoneExists == true ? "Open Phone" : "Create Phone…") : "Download…") {
                setup.selectVersion(id: version.runtime.id)
                if setup.stage == .complete { openLibrary() }
            }.disabled(available == nil || cancelling)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func openLibrary() {
        if let sdk = setup.installedSDK { finish(sdk) }
        dismiss()
    }
}

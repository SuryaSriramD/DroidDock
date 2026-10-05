import Foundation
import SimulatorKit

struct AndroidVersionAvailability: Equatable {
    let downloadBytes: Int64
    let requiredDiskBytes: Int64
    let installed: Bool
    let phoneExists: Bool

    static func inspect(_ plan: AndroidInstallPlan) throws -> Self {
        let runtime = ManagedAndroidRuntime()
        return try Self(downloadBytes: runtime.missingDownloadBytes(for: plan),
                        requiredDiskBytes: runtime.requiredAdditionalDiskBytes(for: plan),
                        installed: runtime.isRuntimeInstalled(plan.runtime),
                        phoneExists: runtime.phoneExists(plan.runtime))
    }
}

/// Loading the catalog never starts a runtime download. Each selection gets a
/// fresh review; consent is tied to that version and its current download needs.
@MainActor
final class AndroidSetupModel: ObservableObject {
    enum Stage { case welcome, loading, versions, review, installing, complete }
    typealias Load = () async throws -> [AndroidInstallPlan]
    typealias Inspect = (AndroidInstallPlan) throws -> AndroidVersionAvailability
    typealias Install = (AndroidInstallPlan, @escaping @Sendable (AndroidSetupProgress) -> Void) async throws -> URL

    @Published private(set) var stage: Stage = .welcome
    @Published private(set) var versions: [AndroidInstallPlan] = []
    @Published private(set) var availability: [String: AndroidVersionAvailability] = [:]
    @Published private(set) var availabilityErrors: [String: String] = [:]
    @Published private(set) var plan: AndroidInstallPlan?
    @Published private(set) var reviewedAvailability: AndroidVersionAvailability?
    @Published private(set) var progress = AndroidSetupProgress(message: "Preparing Android…", fraction: nil)
    @Published private(set) var error: String?
    @Published private(set) var installedSDK: URL?
    @Published var acceptedLicenses = false
    private let load: Load
    private let inspect: Inspect
    private let install: Install
    private let sdkRoot: URL
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private(set) var presentationID = UUID()
    var isBusy: Bool { operation != nil }
    var installedDeviceName: String? { plan?.runtime.deviceName }
    var needsDownload: Bool { (reviewedAvailability?.downloadBytes ?? 0) > 0 }
    var canInstall: Bool { stage == .review && !isBusy && reviewedAvailability != nil && (!needsDownload || acceptedLicenses) }

    init(load: @escaping Load = { try await AndroidPackageCatalog.loadAvailable() },
         inspect: @escaping Inspect = AndroidVersionAvailability.inspect,
         sdkRoot: URL = ManagedAndroidRuntime.defaultRoot.appendingPathComponent("sdk"),
         install: @escaping Install = { plan, progress in
             try await ManagedAndroidRuntime().install(plan: plan, progress: progress)
         }) {
        self.load = load; self.inspect = inspect; self.sdkRoot = sdkRoot; self.install = install
    }

    func prepare() {
        guard operation == nil else { return }
        stage = .loading; error = nil; plan = nil; reviewedAvailability = nil
        acceptedLicenses = false; installedSDK = nil; versions = []; availability = [:]; availabilityErrors = [:]
        let id = UUID(); operationID = id
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if operationID == id { operation = nil } }
            do {
                let result = try await load()
                try Task.checkCancellation()
                guard operationID == id else { return }
                guard !result.isEmpty else { throw RuntimeError.invalidArgument("No compatible Android versions are available. Try again later.") }
                versions = result
                for version in result {
                    do { availability[version.runtime.id] = try inspect(version) }
                    catch { availabilityErrors[version.runtime.id] = error.localizedDescription }
                }
                stage = .versions
            } catch {
                if operationID == id {
                    if !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
                    stage = .welcome
                }
            }
        }
    }

    func beginPresentation(loadCatalog: Bool) {
        guard !isBusy else { return }
        presentationID = UUID()
        stage = .welcome; error = nil; plan = nil; reviewedAvailability = nil
        acceptedLicenses = false; installedSDK = nil
        versions = []; availability = [:]; availabilityErrors = [:]
        if loadCatalog { prepare() }
    }

    func selectVersion(id: String) {
        guard !isBusy, stage == .versions, let selection = versions.first(where: { $0.runtime.id == id }) else { return }
        error = nil; acceptedLicenses = false; installedSDK = nil
        do {
            let current = try inspect(selection)
            availability[id] = current; availabilityErrors[id] = nil
            plan = selection; reviewedAvailability = current
            if current.installed && current.phoneExists {
                installedSDK = sdkRoot; stage = .complete
            } else { stage = .review }
        } catch { self.error = error.localizedDescription }
    }

    func backToVersions() {
        guard !isBusy else { return }
        plan = nil; reviewedAvailability = nil; acceptedLicenses = false; error = nil; stage = .versions
    }

    func startInstall() {
        guard canInstall, let plan else { return }
        do {
            let current = try inspect(plan)
            guard current == reviewedAvailability else {
                reviewedAvailability = current; availability[plan.runtime.id] = current; acceptedLicenses = false
                error = "The installed components changed. Review the updated download before continuing."
                return
            }
        } catch { self.error = error.localizedDescription; acceptedLicenses = false; return }
        stage = .installing; error = nil
        progress = AndroidSetupProgress(message: "Preparing Android…", fraction: nil)
        let id = UUID(); operationID = id
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if operationID == id { operation = nil } }
            do {
                let sdk = try await install(plan) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == id, self.stage == .installing else { return }
                        self.progress = update
                    }
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                installedSDK = sdk; stage = .complete
            } catch {
                if operationID == id {
                    if !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
                    stage = .review
                }
            }
        }
    }

    func cancel() async {
        operation?.cancel()
        await operation?.value
    }

    func cancel(presentationID: UUID) async {
        guard presentationID == self.presentationID else { return }
        await cancel()
    }

    func resetCompletedSetup() {
        guard !isBusy, stage == .complete else { return }
        stage = .welcome; installedSDK = nil; plan = nil; reviewedAvailability = nil; acceptedLicenses = false; error = nil
    }
}

import Foundation
import SimulatorKit

@MainActor
protocol AppUpdatePreferences: AnyObject {
    var automaticallyChecks: Bool { get set }
    var lastAttempt: Date? { get set }
    var lastSuccessfulCheck: Date? { get set }
}

@MainActor
private final class UserDefaultsAppUpdatePreferences: AppUpdatePreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var automaticallyChecks: Bool {
        get { defaults.object(forKey: "automaticallyChecksAppUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "automaticallyChecksAppUpdates") }
    }
    var lastAttempt: Date? {
        get { defaults.object(forKey: "lastAppUpdateAttempt") as? Date }
        set { defaults.set(newValue, forKey: "lastAppUpdateAttempt") }
    }
    var lastSuccessfulCheck: Date? {
        get { defaults.object(forKey: "lastSuccessfulAppUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastSuccessfulAppUpdateCheck") }
    }
}

@MainActor
final class AppUpdateModel: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case available(AppReleaseUpdate)
        case upToDate(latestVersion: String)
        case newerLocalBuild(latestVersion: String)
        case failed(String)
    }

    static let shared = AppUpdateModel(canPresentAutomatically: { AppModel.shared.canPresentAppUpdates })
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    let installedVersion: String
    @Published var showingUpdateSheet = false
    @Published var automaticallyChecks: Bool {
        didSet { preferences.automaticallyChecks = automaticallyChecks }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    var isChecking: Bool { operation != nil }
    private let preferences: any AppUpdatePreferences
    private let now: @MainActor () -> Date
    private let load: @MainActor (String) async throws -> AppReleaseCheckResult
    private let canPresentAutomatically: @MainActor () -> Bool
    private var pendingAutomaticPresentation = false
    private var operation: Task<Void, Never>?

    init(installedVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         preferences: (any AppUpdatePreferences)? = nil,
         now: @escaping @MainActor () -> Date = Date.init,
         canPresentAutomatically: @escaping @MainActor () -> Bool = { true },
         load: @escaping @MainActor (String) async throws -> AppReleaseCheckResult = { try await AppReleaseUpdater.check(installedVersion: $0) }) {
        let preferences = preferences ?? UserDefaultsAppUpdatePreferences()
        self.installedVersion = installedVersion ?? "Development build"
        self.preferences = preferences; self.now = now; self.load = load
        self.canPresentAutomatically = canPresentAutomatically
        automaticallyChecks = preferences.automaticallyChecks
        lastChecked = preferences.lastSuccessfulCheck
    }

    func checkAutomaticallyIfNeeded() async {
        guard automaticallyChecks, operation == nil else { return }
        if pendingAutomaticPresentation, canPresentAutomatically() {
            pendingAutomaticPresentation = false
            showingUpdateSheet = true
        }
        let current = now()
        if let previous = preferences.lastAttempt, previous <= current,
           current.timeIntervalSince(previous) < Self.automaticCheckInterval { return }
        startCheck(automatic: true)
        await waitForCheck()
    }

    func checkForUpdates() {
        pendingAutomaticPresentation = false
        showingUpdateSheet = true
        guard operation == nil else { return }
        startCheck(automatic: false)
    }

    func waitForCheck() async { await operation?.value }

    func cancel() async {
        operation?.cancel()
        await operation?.value
    }

    private func startCheck(automatic: Bool) {
        pendingAutomaticPresentation = false
        preferences.lastAttempt = now()
        state = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            defer { operation = nil }
            do {
                let result = try await load(installedVersion)
                try Task.checkCancellation()
                let date = now()
                lastChecked = date; preferences.lastSuccessfulCheck = date
                switch result {
                case .available(let update):
                    state = .available(update)
                    if !automatic { showingUpdateSheet = true }
                    else if automaticallyChecks {
                        if canPresentAutomatically() { showingUpdateSheet = true }
                        else { pendingAutomaticPresentation = true }
                    }
                case .upToDate(let version): state = .upToDate(latestVersion: version)
                case .newerLocalBuild(let version): state = .newerLocalBuild(latestVersion: version)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { state = .idle }
                else { state = .failed(error.localizedDescription) }
            }
        }
    }
}

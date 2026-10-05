import Foundation
import SimulatorKit

/// Discovery is read-only until the user explicitly applies terminal setup.
/// Successful opt-in permits subsequent selected-SDK changes to stay in sync.
@MainActor
final class TerminalSetupModel: ObservableObject {
    enum State: Equatable {
        case idle
        case settingUp
        case ready(hasAndroid: Bool)
        case requiresInstallation
        case failed(String)
    }

    typealias Install = @Sendable (URL, SDKInstallation?) async throws -> Void
    static let enabledDefaultsKey = "DroidDock.TerminalSetup.Enabled"
    static let offeredDefaultsKey = "DroidDock.TerminalSetup.Offered"
    @Published private(set) var state: State = .idle
    @Published private(set) var isWorking = false
    @Published var isPresented = false
    @Published private(set) var selectedSDK: SDKInstallation? = nil
    @Published private(set) var isEnabled: Bool
    var canSetUp: Bool { eligible && !isWorking }
    private let appBundle: URL
    private let eligible: Bool
    private let install: Install
    private let defaults: UserDefaults
    private struct Request: Equatable { let sdk: SDKInstallation? }
    private var requested: Request?
    private var attempted: Request?
    private var operation: Task<Void, Never>?

    init(appBundle: URL = Bundle.main.bundleURL,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         defaults: UserDefaults = .standard,
         install: @escaping Install = { app, sdk in
             try await Task.detached(priority: .utility) {
                 _ = try TerminalEnvironmentInstaller().install(appBundle: app, sdk: sdk)
             }.value
         }) {
        self.appBundle = appBundle
        self.eligible = Self.isInstalledApplication(appBundle, homeDirectory: homeDirectory)
        self.install = install
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    static func isInstalledApplication(_ app: URL, homeDirectory: URL) -> Bool {
        guard app.isFileURL, app.pathExtension == "app" else { return false }
        let actual = app.standardizedFileURL.resolvingSymlinksInPath().path
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     homeDirectory.appendingPathComponent("Applications", isDirectory: true)]
        return roots.contains { actual.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
    }

    func configure(sdk: SDKInstallation?) async {
        selectedSDK = sdk
        requested = Request(sdk: sdk)
        guard eligible else { state = .requiresInstallation; return }
        if let operation { await operation.value; return }
        guard isEnabled else { return }
        await processRequests()
    }

    func presentSetup() {
        if eligible { defaults.set(true, forKey: Self.offeredDefaultsKey) }
        else { state = .requiresInstallation }
        isPresented = true
    }

    func presentIfNeeded() {
        guard eligible, !isEnabled, !defaults.bool(forKey: Self.offeredDefaultsKey) else { return }
        presentSetup()
    }

    func dismissSetup() {
        if eligible { defaults.set(true, forKey: Self.offeredDefaultsKey) }
        isPresented = false
    }

    /// This action is the initial authorization and the only explicit retry.
    /// Failed setup never grants consent for automatic future profile writes.
    func applySetup() async {
        guard eligible else { state = .requiresInstallation; return }
        defaults.set(true, forKey: Self.offeredDefaultsKey)
        if let operation { await operation.value; return }
        if requested == nil { requested = Request(sdk: selectedSDK) }
        attempted = nil
        await processRequests(explicitlyApproved: true)
    }

    private func processRequests(explicitlyApproved: Bool = false) async {
        guard isEnabled || explicitlyApproved else { return }
        if let operation { await operation.value; return }
        guard requested != attempted else { return }
        isWorking = true
        let task = Task {
            defer { operation = nil; isWorking = false }
            // An SDK change during setup is applied after the current write
            // completes, so profiles are never edited by concurrent requests.
            while let request = requested, request != attempted {
                attempted = request
                state = .settingUp
                do {
                    try await install(appBundle, request.sdk)
                    isEnabled = true
                    defaults.set(true, forKey: Self.enabledDefaultsKey)
                    if requested == request { state = .ready(hasAndroid: request.sdk != nil) }
                } catch {
                    if requested == request { state = .failed(error.localizedDescription) }
                }
            }
        }
        operation = task
        await task.value
    }

    func waitForSetup() async { await operation?.value }
}

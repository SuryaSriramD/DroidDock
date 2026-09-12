import Foundation

/// A session-scoped orientation override requested by the user. WindowManager's
/// synchronous lock prevents an emulator sensor or asynchronous settings update
/// from undoing rotation. Original policy/settings are restored on detach/stop.
public actor GuestRotation {
    private let adb: ADBService
    private var original: (auto: String, rotation: String, policy: String)?
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    public init(adb: ADBService) { self.adb = adb }
    public func prepare() async throws {
        await beginOperation()
        defer { endOperation() }
        try Task.checkCancellation()
        try await rememberOriginal()
        let angle = Int(original?.rotation ?? "0") ?? 0
        _ = try await command(["wm", "user-rotation", "lock", String(angle)])
        try Task.checkCancellation()
    }
    public func rotate(to angle: Int) async throws {
        guard (0...3).contains(angle) else { throw RuntimeError.invalidArgument("Rotation must be between 0 and 3.") }
        await beginOperation()
        defer { endOperation() }
        try Task.checkCancellation()
        try await rememberOriginal()
        _ = try await command(["wm", "user-rotation", "lock", String(angle)])
        try Task.checkCancellation()
    }
    /// Restore independently of caller cancellation. False preserves the
    /// original snapshot so the caller can retain this controller and retry
    /// when ADB recovers; cleanup must not claim success or discard it then.
    @discardableResult
    public func restore() async -> Bool {
        await beginOperation()
        defer { endOperation() }
        guard let previous = original else { return true }
        let adb = adb
        let restored = await Task.detached(priority: .utility) {
            let policy = previous.policy.split(whereSeparator: \.isWhitespace).map(String.init)
            let restorePolicy = ["wm", "user-rotation"] + policy
            let settings = [("user_rotation", previous.rotation), ("accelerometer_rotation", previous.auto)].map { key, value in
                value == "null" ? ["settings", "--user", "current", "delete", "system", key] : ["settings", "--user", "current", "put", "system", key, value]
            }
            // Reapply the entire ordered set on retry: wm can itself change the
            // settings, so retrying only a failed command could undo a success.
            for attempt in 0..<2 {
                var succeeded = true
                for args in [restorePolicy] + settings {
                    do { _ = try await adb.run(ADBService.shellArguments(for: args), timeout: 3) }
                    catch { succeeded = false }
                }
                if succeeded { return true }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 150_000_000) }
            }
            return false
        }.value
        if restored { original = nil }
        return restored
    }
    private func rememberOriginal() async throws {
        guard original == nil else { return }
        let auto = try await command(["settings", "--user", "current", "get", "system", "accelerometer_rotation"])
        let rotation = try await command(["settings", "--user", "current", "get", "system", "user_rotation"])
        let policy = try await command(["wm", "user-rotation"])
        try Task.checkCancellation()
        let fields = policy.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields == ["free"] || (fields.count == 2 && fields[0] == "lock" && Int(fields[1]).map({ (0...3).contains($0) }) == true) else {
            throw RuntimeError.invalidArgument("The device did not return a restorable rotation policy. Rotation was left unchanged.")
        }
        original = (auto, rotation, policy)
    }
    /// Actor methods reenter while ADB is awaited. Keep one logical operation
    /// in flight so snapshots and their guest mutations cannot interleave.
    private func beginOperation() async {
        if !operationInProgress { operationInProgress = true; return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }
    private func endOperation() {
        if operationWaiters.isEmpty { operationInProgress = false }
        else { operationWaiters.removeFirst().resume() }
    }
    private func command(_ args: [String]) async throws -> String {
        try await adb.run(ADBService.shellArguments(for: args), timeout: 5).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

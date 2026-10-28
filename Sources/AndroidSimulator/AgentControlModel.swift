import AppKit
import SwiftUI
import SimulatorKit

@MainActor
final class AgentControlModel: ObservableObject {
    static let shared = AgentControlModel()
    struct Connection { var seen: Date; let selfTest: Bool; var initialized = false }
    struct Pending: Identifiable {
        let id: String
        let connection: UUID
        let device: String
        let identity: String
        let client: String
    }
    struct Grant {
        let pending: Pending
        let handle: UUID
        let roots: [String]
        var inspection: AgentValue?
    }
    struct Operation { let device: String; let connection: UUID; let task: Task<String, Error> }
    @Published private(set) var connections: [UUID: Connection] = [:]
    @Published private(set) var pending: [String: Pending] = [:]
    @Published private(set) var grants: [String: Grant] = [:]
    private var operations: [UUID: Operation] = [:]
    private weak var currentModel: AppModel?
    private var timer: Timer?
    private var audit: [(String, String, Date)] = []
    var connectedCount: Int { connections.values.filter { !$0.selfTest && $0.initialized }.count }
    let artifacts: URL

    init(artifacts: URL? = nil) {
        self.artifacts = artifacts ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AndroidSimulator/AgentArtifacts", isDirectory: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
    }
    private func failure(_ message: String) -> Error { SimulatorCommandError.invalidRequest(message) }
    private func session(_ device: String, model suppliedModel: AppModel? = nil) throws -> SessionController {
        let model = suppliedModel ?? currentModel ?? AppModel.shared
        guard let avd = model.devices.first(where: { $0.id == device }),
              let session = model.librarySession(for: avd), session.runtime?.process.isRunning == true, session.state == .running else {
            throw failure("Phone is not running in this DroidDock session. Boot it and request control again.")
        }
        return session
    }
    func expire() {
        for (id, connection) in connections where Date().timeIntervalSince(connection.seen) > 45 { disconnect(id) }
        for (device, grant) in grants {
            if (try? session(device).agentIdentity) != grant.pending.identity { revoke(device) }
        }
    }
    func revoke(_ device: String) {
        for operation in operations.values where operation.device == device { operation.task.cancel() }
        grants[device] = nil
        pending = pending.filter { $0.value.device != device }
    }
    func close() {
        timer?.invalidate(); timer = nil
        for connection in connections.keys { disconnect(connection) }
    }
    private func disconnect(_ connection: UUID) {
        connections[connection] = nil
        for (device, grant) in grants where grant.pending.connection == connection { revoke(device) }
        pending = pending.filter { $0.value.connection != connection }
    }
    func review(_ id: String) {
        guard let request = pending[id] else { return }
        let alert = NSAlert()
        alert.messageText = "Allow \(request.client) to control \(request.device)?"
        alert.informativeText = "Client identity is unverified. Full Android guest shell can erase guest data and access its network. You can revoke control at any time. Next choose optional host folders for APK reads and file transfers."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Grant Full Guest Control")
        guard alert.runModal() == .alertSecondButtonReturn else { pending[id] = nil; return }
        let panel = NSOpenPanel()
        panel.title = "Allow host folders (Cancel grants guest-only control)"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        let roots = panel.runModal() == .OK ? panel.urls.map { $0.resolvingSymlinksInPath().path } : []
        do { try approve(id, roots: roots) }
        catch { let errorAlert = NSAlert(error: error); errorAlert.runModal() }
    }
    func approve(_ id: String, roots: [String]) throws {
        guard let request = pending[id], connections[request.connection] != nil,
              try session(request.device).agentIdentity == request.identity,
              grants[request.device] == nil else { throw failure("Control request expired or the phone changed. Ask the agent to retry.") }
        grants[request.device] = Grant(pending: request, handle: UUID(), roots: roots)
        pending = pending.filter { $0.value.device != request.device }
    }
    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    func execute(_ envelope: AgentEnvelope, model: AppModel, handler: TerminalCommandHandler) async throws -> String {
        currentModel = model
        guard envelope.version == 1, envelope.tool.utf8.count < 100 else { throw failure("Unsupported agent protocol. Update DroidDock and reconnect.") }
        expire()
        let connection = envelope.connection
        if envelope.tool == "handshake" {
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attrs = try FileManager.default.attributesOfItem(atPath: artifacts.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw failure("Unsafe agent artifact directory.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifacts.path)
            for file in (try? FileManager.default.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                if file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                   let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) > 600 {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            connections[connection] = Connection(seen: Date(), selfTest: envelope.args["selfTest"] == .bool(true))
            return try json(["version": 1, "artifacts": artifacts.path])
        }
        guard connections[connection] != nil else { throw failure("Agent connection expired. Reconnect to DroidDock.") }
        connections[connection]?.seen = Date()
        switch envelope.tool {
        case "client_initialized": connections[connection]?.initialized = true; return try json(["success": true])
        case "heartbeat": return try json(["success": true])
        case "disconnect": disconnect(connection); return try json(["success": true])
        case "cancel":
            if let text = envelope.args["request"]?.string, let id = UUID(uuidString: text), operations[id]?.connection == connection { operations[id]?.task.cancel() }
            return try json(["success": true])
        case "list_devices", "device_status", "boot_device":
            let device = envelope.args["device"]?.string
            guard envelope.tool == "list_devices" || device?.isEmpty == false else { throw failure("An explicit phone ID is required.") }
            if let device { guard model.devices.contains(where: { $0.id == device }) else { throw failure("Unknown phone ID.") } }
            let action: SimulatorCommandAction = envelope.tool == "list_devices" ? .list : envelope.tool == "device_status" ? .status : .boot
            let response = await handler.execute(SimulatorCommandRequest(action: action, device: device, timeout: 180))
            guard response.success else { throw failure(response.message) }
            let devices: [[String: Any]] = response.devices.map { device in
                var item: [String: Any] = ["id": device.id, "name": device.name, "state": device.state, "canStop": device.isOwned]
                if let serial = device.serial { item["serial"] = serial }
                return item
            }
            return try json(envelope.tool == "list_devices" ? ["devices": devices] : ["status": devices.first ?? [:]])
        default: break
        }
        guard let device = envelope.args["device"]?.string, !device.isEmpty else { throw failure("An explicit phone ID is required.") }
        let session = try session(device, model: model)
        let identity = session.agentIdentity
        if envelope.tool == "request_control" {
            if let grant = grants[device] {
                guard grant.pending.connection == connection, grant.pending.identity == identity else { throw failure("device_busy: Another agent controls this phone. Revoke it in DroidDock.") }
                return try json(["handle": grant.handle.uuidString.lowercased()])
            }
            guard let client = envelope.args["client"]?.string, !client.isEmpty, client.count <= 100 else { throw failure("Provide a client name of at most 100 characters.") }
            let key = "\(connection):\(device)"
            pending[key] = Pending(id: key, connection: connection, device: device, identity: identity, client: client)
            return try json(["error": "confirmation_required", "message": "Approve this request in DroidDock Agent Setup, then retry."])
        }
        guard let grant = grants[device], grant.pending.connection == connection, grant.pending.identity == identity,
              let handle = envelope.args["handle"]?.string, UUID(uuidString: handle) == grant.handle else {
            throw failure("Control grant is missing, revoked or stale. Request control in DroidDock.")
        }
        if envelope.tool == "release_control" { revoke(device); return try json(["success": true]) }
        if envelope.tool == "stop_device" { revoke(device); await session.stop(); return try json(["success": true]) }
        guard !operations.values.contains(where: { $0.device == device }) else { throw failure("device_busy: Wait for the current agent operation.") }
        let operation = Task { @MainActor () throws -> String in
            try await session.runTerminalADBAction { adb in
                let name = try await adb.run(["emu", "avd", "name"], timeout: 5).text.split(whereSeparator: \.isNewline).map(String.init).filter { $0 != "OK" }
                try Task.checkCancellation()
                guard self.grants[device]?.handle == grant.handle else { throw self.failure("Control was revoked before dispatch.") }
                guard name == [session.avd.name] else { throw self.failure("ADB runtime identity changed. No control was sent.") }
                if envelope.tool == "type_text" {
                    guard let text = envelope.args["text"]?.string, text.utf8.count <= 60_000, session.canControl else { throw self.failure("Open the phone display and provide text within the input limit.") }
                    session.send(.clipboard(text))
                    return try self.json(["success": true, "guestClipboardReplaced": true])
                }
                let app = Bundle.main.bundleURL
                let node = try AgentRuntime.requireNode(in: app)
                let config: [String: AgentValue] = ["adb": .string(adb.sdk.adb.path), "serial": .string(adb.serial), "environment": .object(adb.sdk.environmentOverrides.mapValues { .string($0) }), "roots": .array(grant.roots.map { .string($0) }), "artifacts": .string(self.artifacts.path)]
                var input: [String: AgentValue] = ["config": .object(config), "tool": .string(envelope.tool), "args": .object(envelope.args)]
                if let inspection = grant.inspection { input["inspection"] = inspection }
                let data = try JSONEncoder().encode(input)
                let result = try await ProcessRunner.run(executable: node, arguments: [AgentRuntime.resources(in: app).appendingPathComponent("worker.mjs").path], timeout: 210, standardInput: data)
                try result.requireSuccess(operation: "Agent device operation")
                try Task.checkCancellation()
                guard self.grants[device]?.handle == grant.handle, session.agentIdentity == identity else { throw self.failure("Control revoked or runtime changed; completion may be uncertain.") }
                if envelope.tool == "inspect_device",
                   let reply = try JSONSerialization.jsonObject(with: result.stdout) as? [String: String],
                   let file = reply["artifact"], UUID(uuidString: String(file.dropLast(5))) != nil, file.hasSuffix(".json") {
                    let snapshotURL = self.artifacts.appendingPathComponent(file)
                    var snapshot = try JSONDecoder().decode([String: AgentValue].self, from: Data(contentsOf: snapshotURL))
                    snapshot["image"] = nil
                    self.grants[device]?.inspection = .object(snapshot)
                }
                return result.text
            }
        }
        operations[envelope.request] = Operation(device: device, connection: connection, task: operation)
        defer {
            operations[envelope.request] = nil
            audit.append((envelope.tool, device, Date()))
            if audit.count > 100 { audit.removeFirst() }
        }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
    func testServer() async throws -> String {
        let app = Bundle.main.bundleURL
        let node = try AgentRuntime.requireNode(in: app)
        let result = try await ProcessRunner.run(executable: node, arguments: [AgentRuntime.resources(in: app).appendingPathComponent("self-test.mjs").path, "--command", app.appendingPathComponent("Contents/MacOS/droiddock").path, "mcp"], timeout: 40)
        try result.requireSuccess(operation: "Agent server self-test")
        let response = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        return response?["message"] as? String ?? result.text
    }
}

struct AgentSetupView: View {
    @ObservedObject private var agents = AgentControlModel.shared
    @State private var client = "Codex"
    @State private var testResult = ""
    @State private var testing = false
    private var executable: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/droiddock").path }
    private var command: String {
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' mcp"
        return client == "Codex" ? "codex mcp add droiddock -- \(quoted)" : "claude mcp add --transport stdio --scope user droiddock -- \(quoted)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Setup").font(.headline)
            Text(agents.connectedCount > 0 ? "Client Connected (\(agents.connectedCount))" : "No client connected")
            Picker("Client", selection: $client) { Text("Codex").tag("Codex"); Text("Claude Code").tag("Claude Code") }.pickerStyle(.segmented)
            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button("Copy Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
                Button(testing ? "Testing…" : "Test Server") {
                    testing = true
                    Task {
                        do { testResult = try await agents.testServer() }
                        catch { testResult = error.localizedDescription }
                        testing = false
                    }
                }.disabled(testing)
            }
            Button("Copy Configuration Snippet") {
                let text: String
                if client == "Codex" {
                    guard let data = try? JSONSerialization.data(withJSONObject: executable, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                          let quoted = String(data: data, encoding: .utf8) else { return }
                    text = "[mcp_servers.droiddock]\ncommand = \(quoted)\nargs = [\"mcp\"]\nstartup_timeout_sec = 30\ntool_timeout_sec = 240"
                } else {
                    let object: [String: Any] = ["mcpServers": ["droiddock": ["command": executable, "args": ["mcp"], "timeout": 240_000]]]
                    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                          let value = String(data: data, encoding: .utf8) else { return }
                    text = value
                }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
            Text(client == "Codex" ? "Check codex mcp list and /mcp. Remove with codex mcp remove droiddock." : "Check claude mcp list and /mcp. Remove with claude mcp remove --scope user droiddock.").font(.caption)
            Text("For cold boots and large installs, apply the configuration snippet with a 240-second tool timeout. Ask your agent to list devices, boot a phone, and request control. Approve here, then retry. Full guest control can erase Android data and access its network. Client names are unverified.").font(.caption)
            if !testResult.isEmpty { Text(testResult).font(.caption).textSelection(.enabled) }
            ForEach(agents.pending.values.sorted(by: { $0.id < $1.id })) { request in
                Button("Review \(request.client) → \(request.device)") { agents.review(request.id) }
            }
            ForEach(agents.grants.keys.sorted(), id: \.self) { device in
                Button("Revoke \(agents.grants[device]?.pending.client ?? "Agent") → \(device)") { agents.revoke(device) }
            }
        }
    }
}

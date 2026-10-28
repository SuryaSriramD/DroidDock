import XCTest
@testable import AndroidSimulator
import SimulatorKit

@MainActor
final class AgentControlModelTests: XCTestCase {
    private func request(_ tool: String, connection: UUID, args: [String: AgentValue] = [:]) throws -> AgentEnvelope {
        let data = try JSONEncoder().encode(AgentValue.object(["version": .number(1), "connection": .string(connection.uuidString), "request": .string(UUID().uuidString), "tool": .string(tool), "args": .object(args)]))
        return try JSONDecoder().decode(AgentEnvelope.self, from: data)
    }
    func testNoDeviceOperationCanRunWithoutConnectionAndOwnedPhone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controls = AgentControlModel(artifacts: directory)
        defer { controls.close() }
        let model = AppModel()
        let handler = TerminalCommandHandler(model: model)
        let connection = UUID()
        do {
            _ = try await controls.execute(request("android_shell", connection: connection, args: ["device": .string("missing")]), model: model, handler: handler)
            XCTFail("Disconnected agent must not run")
        } catch { XCTAssertTrue(error.localizedDescription.contains("expired")) }
        _ = try await controls.execute(request("handshake", connection: connection, args: ["selfTest": .bool(true)]), model: model, handler: handler)
        XCTAssertEqual(controls.connectedCount, 0)
        _ = try await controls.execute(request("client_initialized", connection: connection), model: model, handler: handler)
        XCTAssertEqual(controls.connectedCount, 0, "Self-test must not appear as a real client")
        do {
            _ = try await controls.execute(request("request_control", connection: connection, args: ["device": .string("missing"), "client": .string("test")]), model: model, handler: handler)
            XCTFail("Unowned phone must not be granted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not running")) }
        XCTAssertTrue(controls.grants.isEmpty)
        _ = try await controls.execute(request("disconnect", connection: connection), model: model, handler: handler)
        XCTAssertTrue(controls.connections.isEmpty)
    }
    func testOwnedGrantDeduplicationConnectionIsolationAndRuntimeReplacement() async throws {
        let fixture = try FixtureSDK()
        let ledger = RuntimeLedger(url: fixture.root.appendingPathComponent("ledger.json"))
        let model = AppModel(runtimeLedger: ledger)
        model.sdkPath = fixture.installation.root.path
        let avd = AVD(name: "Fixture_AVD", architecture: "arm64-v8a")
        let controller = SessionController(avd: avd, sdk: fixture.installation,
            manager: EmulatorProcessManager(logDirectory: fixture.root.appendingPathComponent("logs")),
            runtimeLedger: ledger, journalURL: fixture.root.appendingPathComponent("journal.jsonl"),
            failureEvidenceStore: RuntimeFailureEvidenceStore(directoryURL: fixture.root.appendingPathComponent("failure-evidence")),
            isQuitting: { model.isQuitting }, bridgeFactory: { _, _ in TerminalStopFixtureBridge() })
        model.sessions[avd.id] = controller
        let controls = AgentControlModel(artifacts: fixture.root.appendingPathComponent("agent-artifacts"))
        addTeardownBlock { @MainActor in
            controls.close()
            try? fixture.mark("shutdown")
            await controller.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        controller.start()
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while controller.state != .running {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.executableRuntimeMismatch) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await model.refresh()
        let handler = TerminalCommandHandler(model: model)
        let connection = UUID()
        _ = try await controls.execute(request("handshake", connection: connection), model: model, handler: handler)
        let args: [String: AgentValue] = ["device": .string(avd.id), "client": .string("Codex")]
        for _ in 0..<2 {
            let result = try await controls.execute(request("request_control", connection: connection, args: args), model: model, handler: handler)
            XCTAssertTrue(result.contains("confirmation_required"))
        }
        XCTAssertEqual(controls.pending.count, 1)
        try controls.approve(try XCTUnwrap(controls.pending.keys.first), roots: [])
        let response = try await controls.execute(request("request_control", connection: connection, args: args), model: model, handler: handler)
        let result = try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: String]
        let handle = try XCTUnwrap(result["handle"])
        XCTAssertNotNil(UUID(uuidString: handle))
        let second = UUID()
        _ = try await controls.execute(request("handshake", connection: second), model: model, handler: handler)
        do {
            _ = try await controls.execute(request("request_control", connection: second, args: args), model: model, handler: handler)
            XCTFail("A second connection must not control the phone")
        } catch { XCTAssertTrue(error.localizedDescription.contains("device_busy")) }
        let oldIdentity = controller.agentIdentity
        await controller.stop()
        XCTAssertNotEqual(controller.agentIdentity, oldIdentity)
        controls.expire()
        XCTAssertTrue(controls.grants.isEmpty)
        do {
            _ = try await controls.execute(request("press_key", connection: connection, args: ["device": .string(avd.id), "handle": .string(handle), "key": .string("back")]), model: model, handler: handler)
            XCTFail("A stopped runtime must reject its old handle")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not running")) }
    }

}

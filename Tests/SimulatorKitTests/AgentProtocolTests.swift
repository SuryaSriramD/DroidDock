import XCTest
@testable import SimulatorKit

final class AgentProtocolTests: XCTestCase {
    func testAgentEnvelopeRoundTripsWithoutChangingLegacyCommands() throws {
        let text = """
        {"version":1,"connection":"790946d1-e08e-4e1d-910d-9f771179c828","request":"bf4b731a-9a03-4f71-ad60-f10a980f2cd8","tool":"android_shell","args":{"device":"phone","args":["printf","a'b"],"timeout":30}}
        """
        let decoded = try JSONDecoder().decode(AgentEnvelope.self, from: Data(text.utf8))
        XCTAssertEqual(decoded.args["device"]?.string, "phone")
        let encoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(try JSONDecoder().decode(AgentEnvelope.self, from: encoded).args, decoded.args)
        XCTAssertNoThrow(try SimulatorCommandRequest(action: .agentCall, argument: text).validated())
        XCTAssertEqual(try SimulatorCLIOptions.parse(["agent-call", "--json"]).action, .agentCall)
        XCTAssertEqual(try SimulatorCLIOptions.parse(["list", "--json"]).action, .list)
        XCTAssertThrowsError(try SimulatorCommandRequest(action: .agentCall, argument: text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")).validated())
        XCTAssertThrowsError(try SimulatorCommandRequest(action: .agentCall, argument: String(repeating: "x", count: 60_001)).validated())
    }
    func testSharedEnvelopeFixtures() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("agent/fixtures/contract.json")
        let examples = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: [[String: Any]]]
        for value in examples["valid"]! {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            XCTAssertNoThrow(try SimulatorCommandRequest(action: .agentCall, argument: text).validated())
        }
        for value in examples["invalid"]! {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            XCTAssertThrowsError(try SimulatorCommandRequest(action: .agentCall, argument: text).validated())
        }
    }
    func testProcessInputIsDeliveredAndCancellationRemainsBounded() async throws {
        let input = Data([0, 255, 12, 10])
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: input)
        XCTAssertEqual(result.stdout, input)
        XCTAssertEqual(result.status, 0)
    }
}

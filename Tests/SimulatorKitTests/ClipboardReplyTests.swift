import XCTest
@testable import SimulatorKit

final class ClipboardReplyTests: XCTestCase {
    func testRequestPacketAndUnicodeReply() async throws {
        XCTAssertEqual(ScrcpyControlEncoder.encode(.getClipboard), Data([8, 0]))
        let channel = ClipboardReplyChannel()
        let result = try await channel.request { channel.receive("Android → Mac 日本語 🙂") }
        XCTAssertEqual(result, "Android → Mac 日本語 🙂")
        let empty = try await channel.request { channel.receive("") }
        XCTAssertEqual(empty, "")
    }

    func testTimeoutLateReplyCannotSatisfyNewRequest() async throws {
        let channel = ClipboardReplyChannel()
        do { _ = try await channel.request(timeout: 0.02) {}; XCTFail("Expected timeout") } catch { }
        do { _ = try await channel.request { XCTFail("Unanswered request must block another send") }; XCTFail("Expected pending-reply error") } catch { }
        channel.receive("late reply must be discarded")
        let result = try await channel.request { channel.receive("new reply") }
        XCTAssertEqual(result, "new reply")
    }

    func testCancellationConsumesLateReplyBeforeReuse() async throws {
        let channel = ClipboardReplyChannel(), sent = expectation(description: "request sent")
        let task = Task { try await channel.request { sent.fulfill() } }
        await fulfillment(of: [sent], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        channel.receive("cancelled response")
        let result = try await channel.request { channel.receive("next") }
        XCTAssertEqual(result, "next")
    }

    func testCloseReleasesWaiterAndRejectsFutureRequests() async throws {
        let channel = ClipboardReplyChannel(), sent = expectation(description: "request sent")
        let task = Task { try await channel.request { sent.fulfill() } }
        await fulfillment(of: [sent], timeout: 1)
        channel.close()
        do { _ = try await task.value; XCTFail("Expected disconnected cancellation") } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await channel.request { XCTFail("Closed channel must not send") }; XCTFail("Expected closed error") } catch { }
    }
}

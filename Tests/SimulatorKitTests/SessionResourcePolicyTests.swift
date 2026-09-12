import XCTest
@testable import SimulatorKit

final class SessionResourcePolicyTests: XCTestCase {
    func testFirstDeviceDoesNotWarnEvenWhenConfiguredMemoryExceedsHost() {
        XCTAssertNil(SessionResourcePolicy.warning(newDevice: AVD(name: "Large", memoryMB: 32_768),
            existingDevices: [], physicalMemoryBytes: 8 * gib, knownResidentBytes: nil),
            "This policy is an additional-session advisory, not an inferred RAM admission limit")
    }

    func testAdditionalDeviceWarnsAndIncludesNewAndExistingConfiguredMemory() throws {
        let message = try XCTUnwrap(SessionResourcePolicy.warning(newDevice: AVD(name: "Second", displayName: "Second phone", memoryMB: 4_096),
            existingDevices: [AVD(name: "First", memoryMB: 2_048)], physicalMemoryBytes: 16 * gib, knownResidentBytes: 3 * gib / 2))
        XCTAssertTrue(message.contains("Starting Second phone"))
        XCTAssertTrue(message.contains("2 devices starting or running"))
        XCTAssertTrue(message.contains("Configured guest RAM: 6.0 GiB across 2 devices"))
        XCTAssertTrue(message.contains("Host physical RAM: 16.0 GiB"))
        XCTAssertTrue(message.contains("Current emulator resident memory: 1.5 GiB (available samples only)"))
        XCTAssertTrue(message.contains("not a measurement of available RAM or memory pressure"))
        XCTAssertTrue(message.contains("continue or cancel"))
    }

    func testWarnsForAdditionalLightSessionWithoutClaimingInsufficientMemory() throws {
        let message = try XCTUnwrap(SessionResourcePolicy.warning(newDevice: AVD(name: "Tiny", memoryMB: 128),
            existingDevices: [AVD(name: "Other", memoryMB: 128)], physicalMemoryBytes: 128 * gib, knownResidentBytes: 0))
        XCTAssertTrue(message.contains("Additional emulators can slow your Mac"))
        XCTAssertTrue(message.contains("Current emulator resident memory: 0.0 GiB"), "A measured zero differs from unavailable data")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("insufficient"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("cannot start"))
    }

    func testUnknownAndInvalidAVDMemoryAreNotCountedAsZero() throws {
        let message = try XCTUnwrap(SessionResourcePolicy.warning(newDevice: AVD(name: "Unknown"),
            existingDevices: [AVD(name: "Known", memoryMB: 2_048), AVD(name: "Invalid", memoryMB: -1)],
            physicalMemoryBytes: 0, knownResidentBytes: nil))
        XCTAssertTrue(message.contains("3 devices starting or running"))
        XCTAssertTrue(message.contains("2.0 GiB across 1 configured device; 2 devices have unknown RAM"))
        XCTAssertTrue(message.contains("Host physical RAM: Unknown"))
        XCTAssertTrue(message.contains("Current emulator resident memory: Unknown; no current samples"))
    }

    func testAllUnknownGuestConfigurationsAreExplicit() throws {
        let message = try XCTUnwrap(SessionResourcePolicy.warning(newDevice: AVD(name: "New"),
            existingDevices: [AVD(name: "Existing")], physicalMemoryBytes: 16 * gib, knownResidentBytes: nil))
        XCTAssertTrue(message.contains("Configured guest RAM: Unknown for all 2 devices"))
        XCTAssertFalse(message.contains("Configured guest RAM: 0.0"))
    }

    func testMalformedLargeConfigurationsCannotOverflowOrReportWrappedTotal() throws {
        let message = try XCTUnwrap(SessionResourcePolicy.warning(newDevice: AVD(name: "Huge3", memoryMB: Int.max),
            existingDevices: [AVD(name: "Huge1", memoryMB: Int.max), AVD(name: "Huge2", memoryMB: Int.max)],
            physicalMemoryBytes: 16 * gib, knownResidentBytes: nil))
        XCTAssertTrue(message.contains("Configured guest RAM: Unknown total; AVD memory values exceed the supported range"))
        XCTAssertTrue(message.contains("3 devices starting or running"))
    }

    private let gib: UInt64 = 1_073_741_824
}

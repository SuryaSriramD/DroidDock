import XCTest
import Darwin
@testable import SimulatorKit

final class ProcessMetricsTests: XCTestCase {
    func testOwnProcessMemoryThreadsAndCPUUseNativeUnits() throws {
        let sampler = ProcessResourceSampler()
        let pid = getpid()
        let initial = try XCTUnwrap(sampler.sample(pid: pid))
        XCTAssertNil(initial.cpuPercent)
        XCTAssertGreaterThan(initial.residentMemoryBytes, 0)
        XCTAssertGreaterThan(initial.threadCount, 0)

        // Touch private pages so resident size, rather than virtual reservation,
        // must reflect this allocation while the buffer remains alive.
        let count = 24 * 1_024 * 1_024
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16_384)
        defer { storage.deallocate() }
        for offset in stride(from: 0, to: count, by: 4096) { storage.storeBytes(of: UInt8(17), toByteOffset: offset, as: UInt8.self) }
        let allocated = try XCTUnwrap(sampler.sample(pid: pid))
        XCTAssertGreaterThan(allocated.residentMemoryBytes, initial.residentMemoryBytes + 12 * 1_024 * 1_024)

        _ = sampler.sample(pid: pid)
        let before = try cpuSeconds()
        let began = ProcessInfo.processInfo.systemUptime
        let deadline = began + 0.25
        var checksum: UInt64 = 1
        repeat {
            for _ in 0..<16_384 { checksum = checksum &* 2862933555777941757 &+ 3037000493 }
        } while ProcessInfo.processInfo.systemUptime < deadline
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let expected = (try cpuSeconds() - before) / elapsed * 100
        let measured = try XCTUnwrap(sampler.sample(pid: pid)?.cpuPercent)
        XCTAssertNotEqual(checksum, 0)
        XCTAssertGreaterThan(expected, 10, "Fixture must consume measurable CPU")
        XCTAssertEqual(measured, expected, accuracy: max(15, expected * 0.2), "Mach counters must match getrusage seconds on this architecture")
    }

    func testMissingAndInvalidProcessDoNotReturnInventedMetrics() {
        let sampler = ProcessResourceSampler()
        XCTAssertNil(sampler.sample(pid: 0))
        XCTAssertNil(sampler.sample(pid: -1))
        XCTAssertNil(sampler.sample(pid: Int32.max))
    }

    func testCPUCanExceedOneHundredPercentAcrossCores() throws {
        guard ProcessInfo.processInfo.activeProcessorCount >= 2 else { throw XCTSkip("Multiple active cores are needed") }
        let sampler = ProcessResourceSampler()
        XCTAssertNotNil(sampler.sample(pid: getpid()))
        let before = try cpuSeconds()
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.concurrentPerform(iterations: 3) { index in
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            var checksum = UInt64(index + 1)
            repeat {
                for _ in 0..<16_384 { checksum = checksum &* 2862933555777941757 &+ 3037000493 }
            } while ProcessInfo.processInfo.systemUptime < deadline
            precondition(checksum != 0)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let expected = (try cpuSeconds() - before) / elapsed * 100
        let measured = try XCTUnwrap(sampler.sample(pid: getpid())?.cpuPercent)
        guard expected > 120 else { throw XCTSkip("Other host work prevented measurable multicore utilization") }
        XCTAssertGreaterThan(measured, 100)
        XCTAssertEqual(measured, expected, accuracy: max(20, expected * 0.2))
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

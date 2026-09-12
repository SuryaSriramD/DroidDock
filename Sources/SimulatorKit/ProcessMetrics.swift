import Foundation
import Darwin

public struct ProcessResourceUsage: Sendable, Equatable {
    /// CPU use over the interval since the last sample. One busy core is 100%;
    /// a process using multiple cores can exceed 100%. The first sample is nil.
    public let cpuPercent: Double?
    /// Resident memory currently held by this exact process, in bytes.
    public let residentMemoryBytes: UInt64
    public let threadCount: Int
}

/// Reads native process counters without launching a shell or sampling child
/// processes. Each PID has its own synchronized CPU baseline. Missing processes
/// and denied kernel reads return nil instead of stale or zero-valued metrics.
public final class ProcessResourceSampler: @unchecked Sendable {
    private struct Observation {
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let userTime: UInt64
        let systemTime: UInt64
        let uptime: TimeInterval
    }

    private let lock = NSLock()
    private var previous: [Int32: Observation] = [:]
    private let secondsPerMachTick: Double?

    public init() {
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 {
            secondsPerMachTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        } else { secondsPerMachTick = nil }
    }

    public func sample(pid: Int32) -> ProcessResourceUsage? {
        lock.withLock {
            guard pid > 0 else { return nil }
            var info = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size,
                  info.pbsd.pbi_pid == UInt32(pid) else {
                previous.removeValue(forKey: pid)
                return nil
            }
            let current = Observation(startSeconds: info.pbsd.pbi_start_tvsec,
                                      startMicroseconds: info.pbsd.pbi_start_tvusec,
                                      userTime: info.ptinfo.pti_total_user,
                                      systemTime: info.ptinfo.pti_total_system,
                                      uptime: ProcessInfo.processInfo.systemUptime)
            var cpuPercent: Double?
            if let old = previous[pid], let secondsPerMachTick,
               old.startSeconds == current.startSeconds,
               old.startMicroseconds == current.startMicroseconds,
               current.userTime >= old.userTime, current.systemTime >= old.systemTime,
               current.uptime > old.uptime {
                // XNU fill_taskprocinfo returns Mach time, including terminated
                // threads. Convert its delta using the host timebase; Apple
                // Silicon counters are not already measured in nanoseconds.
                let ticks = Double(current.userTime - old.userTime) + Double(current.systemTime - old.systemTime)
                let percent = ticks * secondsPerMachTick / (current.uptime - old.uptime) * 100
                if percent.isFinite { cpuPercent = max(0, percent) }
            }
            previous[pid] = current
            // A sampler is normally retained per session; keep a global/shared
            // instance bounded too if callers cycle through many different PIDs.
            if previous.count > 64, let oldest = previous.min(by: { $0.value.uptime < $1.value.uptime })?.key {
                previous.removeValue(forKey: oldest)
            }
            return ProcessResourceUsage(cpuPercent: cpuPercent,
                                        residentMemoryBytes: info.ptinfo.pti_resident_size,
                                        threadCount: max(0, Int(info.ptinfo.pti_threadnum)))
        }
    }
}

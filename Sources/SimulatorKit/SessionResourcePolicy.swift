import Foundation

/// A launch advisory, not an admission limit or memory-pressure detector.
/// Callers include both starting and running sessions in existingDevices and
/// supply the sum of available current RSS samples, or nil when none are known.
public enum SessionResourcePolicy {
    public static func warning(newDevice: AVD, existingDevices: [AVD],
                               physicalMemoryBytes: UInt64, knownResidentBytes: UInt64?) -> String? {
        guard !existingDevices.isEmpty else { return nil }
        let devices = existingDevices + [newDevice]
        let configured = configuredMemory(devices)
        let host = physicalMemoryBytes > 0 ? gibibytes(Double(physicalMemoryBytes)) : "Unknown"
        let resident = knownResidentBytes.map { gibibytes(Double($0)) + " (available samples only)" } ?? "Unknown; no current samples"
        return """
        Starting \(newDevice.displayName) will bring the workspace to \(devices.count) devices starting or running. Additional emulators can slow your Mac.

        Configured guest RAM: \(configured)
        Host physical RAM: \(host)
        Current emulator resident memory: \(resident)

        Configured guest RAM is an estimate from AVD settings, not a measurement of available RAM or memory pressure. Resident memory covers only the existing sessions with current samples. You can continue or cancel this launch.
        """
    }

    private static func configuredMemory(_ devices: [AVD]) -> String {
        var totalMiB: UInt64 = 0
        var known = 0
        var overflowed = false
        for device in devices where device.memoryMB > 0 {
            known += 1
            let sum = totalMiB.addingReportingOverflow(UInt64(device.memoryMB))
            totalMiB = sum.partialValue
            overflowed = overflowed || sum.overflow
        }
        let unknown = devices.count - known
        guard known > 0 else { return "Unknown for all \(devices.count) devices" }
        guard !overflowed else { return "Unknown total; AVD memory values exceed the supported range" }
        // Convert after summing MiB, avoiding overflowing a byte multiplication
        // when a malformed AVD reports an extremely large memory value.
        let total = gibibytes(Double(totalMiB) * 1_048_576)
        if unknown > 0 {
            return "\(total) across \(known) configured \(known == 1 ? "device" : "devices"); \(unknown) \(unknown == 1 ? "device has" : "devices have") unknown RAM"
        }
        return "\(total) across \(devices.count) devices"
    }

    private static func gibibytes(_ bytes: Double) -> String {
        String(format: "%.1f GiB", locale: Locale(identifier: "en_US_POSIX"), bytes / 1_073_741_824)
    }
}

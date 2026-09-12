import Foundation

public struct EmulatorSnapshot: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    /// Console-provided size, date, and VM clock, retained without guessing a time zone.
    public let details: String

    public init(name: String, details: String = "") {
        self.name = name
        self.details = details
    }
}

public enum EmulatorSnapshotError: LocalizedError, Equatable, Sendable {
    case invalidName
    case unsupported(details: String)
    case consoleFailure(operation: String, details: String)
    case malformedResponse(details: String)
    case timedOut(operation: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Use a snapshot name of 1–128 letters, numbers, underscores, dots, or hyphens, starting with a letter, number, or underscore."
        case .unsupported(let details):
            return "Snapshots are unavailable for this emulator session. Check the AVD’s snapshot support and launch settings, and update Android Emulator in SDK Manager if needed.\n\(details)"
        case .consoleFailure(let operation, let details):
            return "Could not \(operation) the snapshot. Check the emulator’s response and refresh snapshots before retrying.\n\(details)"
        case .malformedResponse(let details):
            return "The emulator returned an unrecognized snapshot response. Refresh snapshots and check the SDK emulator version.\n\(details)"
        case .timedOut(let operation, let seconds):
            return "The snapshot \(operation) command did not finish within \(Int(seconds)) seconds. The emulator may still be completing it. Check the device and refresh snapshots before retrying."
        }
    }
}

/// Snapshot operations for an already selected ADB device. The caller must own
/// the emulator, serialize operations, and obtain confirmation before replacing
/// guest state or a saved snapshot. No operation is retried or run automatically.
/// Commands: https://developer.android.com/studio/run/emulator-console
public struct EmulatorSnapshots: Sendable {
    private let adb: ADBService
    private let timeouts: Timeouts

    struct Timeouts: Sendable {
        var list: TimeInterval = 15
        var save: TimeInterval = 120
        var load: TimeInterval = 120
        var delete: TimeInterval = 30
    }

    public init(adb: ADBService) {
        self.adb = adb
        self.timeouts = Timeouts()
    }

    init(adb: ADBService, timeouts: Timeouts) {
        self.adb = adb
        self.timeouts = timeouts
    }

    /// Returns complete snapshots only. QEMU's explicitly non-loadable partial
    /// snapshots are parsed but excluded, so they cannot be offered for restore.
    public func list() async throws -> [EmulatorSnapshot] {
        try Self.parseListBody(await command("list", timeout: timeouts.list))
    }

    public func save(name: String) async throws {
        try Self.validateName(name)
        _ = try await command("save", name: name, timeout: timeouts.save)
    }

    public func load(name: String) async throws {
        try Self.validateName(name)
        _ = try await command("load", name: name, timeout: timeouts.load)
    }

    public func delete(name: String) async throws {
        try Self.validateName(name)
        _ = try await command("delete", name: name, timeout: timeouts.delete)
    }

    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...128).contains(bytes.count), let first = bytes.first,
              isLetterOrNumber(first) || first == 95 else { return false }
        return bytes.allSatisfy { isLetterOrNumber($0) || $0 == 95 || $0 == 45 || $0 == 46 }
    }

    public static func validateName(_ name: String) throws {
        guard isValidName(name) else { throw EmulatorSnapshotError.invalidName }
    }

    private static func isLetterOrNumber(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }

    private func command(_ operation: String, name: String? = nil, timeout: TimeInterval) async throws -> [String] {
        try Task.checkCancellation()
        do {
            let result = try await adb.run(["emu", "avd", "snapshot", operation] + (name.map { [$0] } ?? []), timeout: timeout)
            try Task.checkCancellation()
            return try Self.responseBody(result.text, stderr: result.stderrText, operation: operation)
        } catch RuntimeError.commandFailed(_, _, let details) {
            throw Self.consoleError(operation: operation, details: details)
        } catch RuntimeError.commandTimedOut(_, let seconds) {
            throw EmulatorSnapshotError.timedOut(operation: operation, seconds: seconds)
        }
    }

    // adb emu can exit zero for KO. Check both streams before trusting its OK.
    static func responseBody(_ stdout: String, stderr: String = "", operation: String) throws -> [String] {
        let out = lines(stdout)
        let errors = lines(stderr)
        if let failure = (out + errors).first(where: { line in
            let upper = line.uppercased()
            return upper == "KO" || upper.hasPrefix("KO:") || upper.hasPrefix("KO ")
        }) {
            throw consoleError(operation: operation, details: failure)
        }
        guard out.last == "OK" else {
            throw EmulatorSnapshotError.malformedResponse(details: excerpt((out + errors).joined(separator: "\n")))
        }
        let body = Array(out.dropLast())
        guard !body.contains("OK") else {
            throw EmulatorSnapshotError.malformedResponse(details: "Unexpected extra console acknowledgement.")
        }
        return body
    }

    private static func consoleError(operation: String, details: String) -> EmulatorSnapshotError {
        let lower = details.lowercased()
        let unavailable = ["unsupported", "not supported", "does not support", "no available block device supports snapshots",
                           "unknown command", "bad sub-command", "disabled", "snapshot save is skipped"]
        if unavailable.contains(where: lower.contains) {
            return .unsupported(details: excerpt(details))
        }
        return .consoleFailure(operation: operation, details: excerpt(details))
    }

    /// Table framing follows QEMU qemu_listvms. Refuse unknown rows rather than
    /// silently presenting an empty list or deriving a name from diagnostic text.
    /// https://android.googlesource.com/platform/external/qemu/+/emu-master-dev/migration/savevm.c
    static func parseListBody(_ body: [String]) throws -> [EmulatorSnapshot] {
        var snapshots: [EmulatorSnapshot] = []
        var names = Set<String>()
        var table = false
        var section = false
        var partial = false
        var empty = false
        var needsBody = false
        let header = #"^ID\s+TAG\s+VM SIZE\s+DATE\s+VM CLOCK(?:\s+ICOUNT)?$"#
        let row = try NSRegularExpression(pattern: #"^(?:[0-9]+|--)\s+([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})\s+([0-9]+(?:\.[0-9]+)?\s*(?:[KMGTPE]i?B?|B)?\s+[0-9]{4}-[0-9]{2}-[0-9]{2}\s+[0-9]{2}:[0-9]{2}:[0-9]{2}\s+[0-9]+:[0-9]{2}:[0-9]{2}\.[0-9]+(?:\s+[0-9]+)?)$"#, options: .caseInsensitive)
        for line in body {
            if line.hasPrefix("Snapshot devices:"), !section, !table, !empty {
                needsBody = true
                continue
            }
            if line == "List of snapshots present on all disks:" || line == "Snapshot list:" ||
                (line.hasPrefix("Snapshot list (from ") && line.hasSuffix("):")) {
                guard !section, !table, !empty else { throw malformed(line) }
                section = true
                needsBody = true
                continue
            }
            if line.hasPrefix("List of partial (non-loadable) snapshots on '") && line.hasSuffix("':") {
                guard section, !needsBody else { throw malformed(line) }
                partial = true
                table = false
                needsBody = true
                continue
            }
            if line.range(of: header, options: .regularExpression) != nil {
                guard !table, partial || !empty else { throw malformed(line) }
                table = true
                section = true
                needsBody = false
                continue
            }
            if line == "There is no snapshot available." || line == "There is no suitable snapshot available" || line == "None" {
                guard !partial, snapshots.isEmpty, !empty, line != "None" || section else { throw malformed(line) }
                empty = true
                needsBody = false
                continue
            }
            guard table, partial || !empty,
                  let match = row.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let detailsRange = Range(match.range(at: 2), in: line) else { throw malformed(line) }
            let name = String(line[nameRange])
            if !partial {
                guard names.insert(name).inserted else { throw malformed("Duplicate snapshot name: \(name)") }
                snapshots.append(EmulatorSnapshot(name: name, details: String(line[detailsRange])))
            }
        }
        guard !needsBody else { throw malformed("The snapshot table ended before its contents.") }
        return snapshots
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func malformed(_ details: String) -> EmulatorSnapshotError {
        .malformedResponse(details: excerpt(details))
    }

    private static func excerpt(_ text: String) -> String {
        text.isEmpty ? "No console acknowledgement was received." : String(text.prefix(2_000))
    }
}

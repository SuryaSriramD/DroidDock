import Darwin
import Foundation

/// Only a validated, unchanged discovery result can authorize moving a phone to Trash.
public struct AVDDeletionPlan: Sendable {
    public let avd: AVD
    public let sdk: SDKInstallation
    public let directoryURL: URL
    public let indexURL: URL
    fileprivate let directoryIdentity: DeletionIdentity
    fileprivate let configSnapshot: DeletionSnapshot
    fileprivate let indexSnapshot: DeletionSnapshot
}

public enum AVDDeletionError: LocalizedError, Equatable {
    case unsafeLocation
    case missingIndex
    case inconsistentIndex
    case sharedDirectory
    case changedOnDisk
    case deviceInUse
    case trashFailed(String)
    case partialTrashFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeLocation:
            return "This phone's files are not in a safely identifiable .avd folder. Its files were not moved."
        case .missingIndex:
            return "This phone has no accessible virtual-device index. Refresh the library before deleting it."
        case .inconsistentIndex:
            return "This phone's index does not match its data folder. Its files were not moved."
        case .sharedDirectory:
            return "Another virtual-device index points to this phone's data folder. Remove the duplicate reference before deleting this phone."
        case .changedOnDisk:
            return "This phone's files changed after deletion was requested. Refresh the library and try again."
        case .deviceInUse:
            return "This phone is in use. Stop it before deleting it."
        case .trashFailed(let details):
            return "The phone could not be moved to Trash. Its original files were preserved. \(details)"
        case .partialTrashFailure(let details):
            return "The phone was only partly moved to Trash and could not be fully restored. \(details)"
        }
    }
}

public enum AVDDeletionStore {
    public static func prepare(avd: AVD, sdk: SDKInstallation) throws -> AVDDeletionPlan {
        guard AVDRepository.isValidName(avd.name), let config = avd.configURL,
              config.lastPathComponent == "config.ini" else { throw AVDDeletionError.unsafeLocation }
        guard let index = avd.indexURL else { throw AVDDeletionError.missingIndex }
        let directory = config.deletingLastPathComponent().standardizedFileURL
        let normalizedIndex = index.standardizedFileURL
        guard directory.lastPathComponent == avd.name + ".avd",
              normalizedIndex.lastPathComponent == avd.name + ".ini",
              !isWithin(sdk.root.standardizedFileURL, directory),
              !isWithin(normalizedIndex, directory),
              !isWithin(directory, sdk.root.standardizedFileURL) else { throw AVDDeletionError.unsafeLocation }
        if let avdHome = sdk.avdHome {
            guard normalizedIndex.deletingLastPathComponent() == avdHome.standardizedFileURL,
                  directory.deletingLastPathComponent() == avdHome.standardizedFileURL else {
                throw AVDDeletionError.unsafeLocation
            }
        }
        let directoryIdentity = try identity(directory, requiredType: S_IFDIR)
        let configSnapshot = try snapshot(config)
        let indexSnapshot = try snapshot(normalizedIndex)
        try validateIndex(indexSnapshot.bytes, at: normalizedIndex, directory: directory)
        try rejectSharedDirectory(directory, index: normalizedIndex, sdk: sdk)
        try ensureNotRunning(directory)
        return AVDDeletionPlan(avd: avd, sdk: sdk, directoryURL: directory, indexURL: normalizedIndex,
                               directoryIdentity: directoryIdentity, configSnapshot: configSnapshot,
                               indexSnapshot: indexSnapshot)
    }

    /// The caller confirms the named phone and rejects all active sessions first.
    /// Shared SDK components and system images are never included in this operation.
    public static func delete(_ plan: AVDDeletionPlan) throws {
        try delete(plan, trash: { url in
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
            return destination as URL?
        })
    }

    /// Injectable only inside the module so tests never touch the user's Trash.
    static func delete(_ plan: AVDDeletionPlan, trash: (URL) throws -> URL?) throws {
        try revalidate(plan)
        // Remove the discovery index first so another ordinary launch cannot
        // find the phone between the two moves. Restore it if the folder fails.
        var trashedIndex: URL?
        do {
            trashedIndex = try trash(plan.indexURL)
        } catch {
            if !exists(plan.indexURL) {
                throw AVDDeletionError.partialTrashFailure("The index may be in Trash: \(plan.indexURL.lastPathComponent). \(error.localizedDescription)")
            }
            throw AVDDeletionError.trashFailed(error.localizedDescription)
        }
        do {
            // A launcher that read the index just before its move must not let
            // us move files belonging to a now-running emulator.
            guard try identity(plan.directoryURL, requiredType: S_IFDIR) == plan.directoryIdentity,
                  try snapshot(plan.directoryURL.appendingPathComponent("config.ini")) == plan.configSnapshot else {
                throw AVDDeletionError.changedOnDisk
            }
            try ensureNotRunning(plan.directoryURL)
            try rejectSharedDirectory(plan.directoryURL, index: plan.indexURL, sdk: plan.sdk)
            _ = try trash(plan.directoryURL)
        } catch {
            let details = error.localizedDescription
            guard exists(plan.directoryURL), let trashedIndex, !exists(plan.indexURL) else {
                throw AVDDeletionError.partialTrashFailure("Check Trash for \(plan.avd.name).ini and \(plan.avd.name).avd. \(details)")
            }
            do {
                // Never overwrite a new index created while the dialog was open.
                guard try snapshot(trashedIndex) == plan.indexSnapshot else { throw AVDDeletionError.changedOnDisk }
                try FileManager.default.moveItem(at: trashedIndex, to: plan.indexURL)
            } catch {
                throw AVDDeletionError.partialTrashFailure("The data folder remains at \(plan.directoryURL.path). Restore the index from \(trashedIndex.path). \(error.localizedDescription)")
            }
            throw AVDDeletionError.trashFailed(details)
        }
    }

    private static func revalidate(_ plan: AVDDeletionPlan) throws {
        let current = try prepare(avd: plan.avd, sdk: plan.sdk)
        guard current.directoryURL == plan.directoryURL, current.indexURL == plan.indexURL,
              current.directoryIdentity == plan.directoryIdentity,
              current.configSnapshot == plan.configSnapshot, current.indexSnapshot == plan.indexSnapshot else {
            throw AVDDeletionError.changedOnDisk
        }
    }

    private static func validateIndex(_ bytes: Data, at index: URL, directory: URL) throws {
        guard let text = String(data: bytes, encoding: .utf8), !bytes.contains(0) else { throw AVDDeletionError.inconsistentIndex }
        var paths: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "path" || key == "path.rel" else { continue }
            guard paths[key] == nil else { throw AVDDeletionError.inconsistentIndex }
            paths[key] = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        guard !paths.isEmpty else { throw AVDDeletionError.inconsistentIndex }
        for (key, value) in paths {
            guard !value.isEmpty else { throw AVDDeletionError.inconsistentIndex }
            let target: URL
            if key == "path" {
                let expanded = NSString(string: value).expandingTildeInPath
                guard expanded.hasPrefix("/") else { throw AVDDeletionError.inconsistentIndex }
                target = URL(fileURLWithPath: expanded, isDirectory: true)
            } else {
                guard !value.hasPrefix("/"), !value.hasPrefix("~"),
                      !value.split(separator: "/").contains("..") else { throw AVDDeletionError.inconsistentIndex }
                target = index.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(value, isDirectory: true)
            }
            guard target.standardizedFileURL == directory else { throw AVDDeletionError.inconsistentIndex }
        }
    }

    private static func ensureNotRunning(_ directory: URL) throws {
        do { try AVDConfigurationStore.requireStoppedDevice(at: directory.appendingPathComponent("config.ini")) }
        catch AVDConfigurationError.deviceInUse { throw AVDDeletionError.deviceInUse }
    }

    private static func rejectSharedDirectory(_ directory: URL, index: URL, sdk: SDKInstallation) throws {
        var homes = Set((sdk.avdHome.map { [$0] } ?? AVDRepository.avdDirectories()).map(\.standardizedFileURL))
        homes.insert(index.deletingLastPathComponent())
        for home in homes {
            guard exists(home) else { continue }
            let entries = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            guard entries.count <= 4096 else { throw AVDDeletionError.unsafeLocation }
            for otherIndex in entries where otherIndex.pathExtension == "ini" && otherIndex.standardizedFileURL != index {
                let contents = try snapshot(otherIndex).bytes
                guard let text = String(data: contents, encoding: .utf8), !contents.contains(0) else {
                    throw AVDDeletionError.unsafeLocation
                }
                for line in text.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let equal = trimmed.firstIndex(of: "=") else { continue }
                    let key = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
                    let value = trimmed[trimmed.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                    let target: URL
                    if key == "path" {
                        let expanded = NSString(string: value).expandingTildeInPath
                        guard expanded.hasPrefix("/") else { continue }
                        target = URL(fileURLWithPath: expanded, isDirectory: true)
                    } else if key == "path.rel" {
                        guard !value.hasPrefix("/") else { continue }
                        target = home.deletingLastPathComponent().appendingPathComponent(value, isDirectory: true)
                    } else { continue }
                    if target.standardizedFileURL.resolvingSymlinksInPath() == directory {
                        throw AVDDeletionError.sharedDirectory
                    }
                }
            }
        }
    }

    private static func snapshot(_ url: URL) throws -> DeletionSnapshot {
        let before = try identity(url, requiredType: S_IFREG)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AVDDeletionError.unsafeLocation }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 1_048_576,
              DeletionIdentity(info) == before else { throw AVDDeletionError.unsafeLocation }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, bytes.count + count <= 1_048_576 else { throw AVDDeletionError.unsafeLocation }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count == info.st_size, try identity(url, requiredType: S_IFREG) == before else {
            throw AVDDeletionError.changedOnDisk
        }
        return DeletionSnapshot(identity: before, bytes: bytes)
    }

    private static func identity(_ url: URL, requiredType: mode_t) throws -> DeletionIdentity {
        guard url.isFileURL, url.standardizedFileURL == url.standardizedFileURL.resolvingSymlinksInPath() else {
            throw AVDDeletionError.unsafeLocation
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == requiredType else { throw AVDDeletionError.unsafeLocation }
        return DeletionIdentity(info)
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isWithin(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }
}

fileprivate struct DeletionIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; mode = info.st_mode
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}

fileprivate struct DeletionSnapshot: Equatable, Sendable {
    let identity: DeletionIdentity
    let bytes: Data
}

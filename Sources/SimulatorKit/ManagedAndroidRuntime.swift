import CryptoKit
import Darwin
import Foundation

public struct AndroidSetupProgress: Sendable {
    public let message: String
    public let fraction: Double?

    public init(message: String, fraction: Double? = nil) {
        self.message = message
        self.fraction = fraction.map { min(1, max(0, $0)) }
    }
}

public enum AndroidSetupError: LocalizedError, Equatable {
    case unsupportedHost
    case installationInProgress
    case invalidPlan(String)
    case insufficientSpace(required: Int64, available: Int64)
    case downloadFailed(String)
    case checksumMismatch(String)
    case unsafeArchive(String)
    case existingInstallation(String)
    case incompleteInstallation(String)
    case sharedToolsUpdateRequired(component: String, minimum: String, installed: String?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost: return "Built-in Android currently requires a Mac with Apple silicon."
        case .installationInProgress: return "Android setup is already running in another DroidDock window."
        case .invalidPlan(let detail): return "Android setup information is invalid: \(detail)"
        case .insufficientSpace(let required, let available):
            return "Android setup needs at least \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) of free space, including room for the virtual phone. Only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available. Free some space and try again."
        case .downloadFailed(let detail): return "Android download failed: \(detail)"
        case .checksumMismatch(let package): return "The downloaded \(package) did not match Google's checksum. Please try setup again."
        case .unsafeArchive(let detail): return "Android setup could not safely unpack an archive: \(detail)"
        case .existingInstallation(let path): return "Setup found existing files at \(path) and preserved them. Choose an existing Android SDK or move those files before trying again."
        case .incompleteInstallation(let detail): return "The Android installation is incomplete: \(detail)"
        case let .sharedToolsUpdateRequired(component, minimum, installed):
            return "This Android version needs \(component) \(minimum) or newer. The installed version is \(installed ?? "unknown"). This DroidDock build cannot update the shared Android engine yet. You can keep using your installed phones and choose versions compatible with this engine."
        }
    }
}

/// Installs only into DroidDock's private directory. Calling install is the
/// caller's acknowledgement that the user accepted this plan's exact licenses.
public struct ManagedAndroidRuntime: Sendable {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DroidDock/Android", isDirectory: true)
    public static let deviceName = "DroidDock_Phone_API_36"
    public static let imagePath = "system-images/android-36/google_apis/arm64-v8a"
    static let markerName = ".droiddock-managed"

    public let root: URL
    public var sdkRoot: URL { root.appendingPathComponent("sdk", isDirectory: true) }
    public var avdHome: URL { root.appendingPathComponent("avd", isDirectory: true) }
    private let dependencies: Dependencies

    public init(root: URL = defaultRoot) {
        self.init(root: root, dependencies: .live)
    }

    init(root: URL, dependencies: Dependencies) {
        self.root = root.standardizedFileURL
        self.dependencies = dependencies
    }

    /// Download/extraction are injectable so rollback, cancellation, and retries
    /// can be exercised without downloading a multi-gigabyte system image.
    struct Dependencies: Sendable {
        var download: @Sendable (AndroidSDKPackage, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
        var extract: @Sendable (URL, URL, String) async throws -> Void
        var availableBytes: @Sendable (URL) throws -> Int64

        static let live = Dependencies(download: { try await ManagedAndroidRuntime.download(package: $0, to: $1, progress: $2) },
                                       extract: { try await ManagedAndroidRuntime.extract(archive: $0, to: $1, archiveRoot: $2) },
                                       availableBytes: { try ManagedAndroidRuntime.availableBytes(at: $0) })
    }

    public func install(plan: AndroidInstallPlan,
                        progress: @escaping @Sendable (AndroidSetupProgress) -> Void) async throws -> URL {
        #if !arch(arm64)
        throw AndroidSetupError.unsupportedHost
        #else
        try Task.checkCancellation()
        try Self.validate(plan: plan)
        try Self.createDirectory(root)
        let installLock = try InstallationLock(root: root)
        defer { installLock.unlock() }
        let incremental = Self.exists(sdkRoot)
        let packages = try packagesToDownload(for: plan)
        try validatePhoneDestination(plan.runtime)
        let required = try requiredAdditionalDiskBytes(for: plan)
        if required > 0 {
            let available = try dependencies.availableBytes(root)
            guard available >= required else {
                throw AndroidSetupError.insufficientSpace(required: required, available: available)
            }
        }
        if packages.isEmpty {
            try Task.checkCancellation()
            try ensureDefaultDevice(version: plan.runtime)
            progress(.init(message: "\(plan.runtime.title) is ready", fraction: 1))
            return sdkRoot
        }
        let staging = root.appendingPathComponent(".setup-\(UUID().uuidString)", isDirectory: true)
        try Self.createDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedSDK = staging.appendingPathComponent("sdk", isDirectory: true)
        try Self.createDirectory(stagedSDK)
        let total = Double(max(1, packages.reduce(Int64(0)) { $0 + $1.archiveBytes }))
        var downloaded: Int64 = 0
        for (index, package) in packages.enumerated() {
            try Task.checkCancellation()
            let archive = staging.appendingPathComponent("package-\(index).zip")
            let completed = Double(downloaded)
            let bytes = Double(package.archiveBytes)
            progress(.init(message: "Downloading \(package.displayName)", fraction: completed / total * 0.8))
            try await dependencies.download(package, archive) { fraction in
                progress(.init(message: "Downloading \(package.displayName)",
                               fraction: (completed + bytes * fraction) / total * 0.8))
            }
            try Task.checkCancellation()
            progress(.init(message: "Checking \(package.displayName)", fraction: (completed + bytes) / total * 0.8))
            try Self.verify(archive: archive, package: package)
            let unpacked = staging.appendingPathComponent("unpacked-\(index)", isDirectory: true)
            try Self.createDirectory(unpacked)
            progress(.init(message: "Installing \(package.displayName)", fraction: (completed + bytes) / total * 0.8))
            try await dependencies.extract(archive, unpacked, package.archiveRoot)
            try Task.checkCancellation()
            try Self.validateExtractedTree(unpacked, archiveRoot: package.archiveRoot)
            let source = unpacked.appendingPathComponent(package.archiveRoot, isDirectory: true)
            let destination = stagedSDK.appendingPathComponent(package.relativeInstallPath, isDirectory: true)
            try Self.createDirectory(destination.deletingLastPathComponent())
            try FileManager.default.moveItem(at: source, to: destination)
            try writeReceipt(package: package, plan: plan, to: destination)
            try FileManager.default.removeItem(at: archive)
            try FileManager.default.removeItem(at: unpacked)
            downloaded += package.archiveBytes
        }
        try Task.checkCancellation()
        progress(.init(message: "Finishing Android installation", fraction: 0.9))
        if incremental { try Self.validateImage(at: stagedSDK, version: plan.runtime) }
        else {
            try Self.validateSDK(at: stagedSDK, version: plan.runtime)
            try writeLicenseAcceptance(plan: plan, to: stagedSDK)
        }
        // Refuse collisions before publishing. Publish the verified image first
        // so a cancellation or failed image rename cannot leave an unusable phone.
        try validatePhoneDestination(plan.runtime)
        try Task.checkCancellation()
        if incremental {
            // Shared tools and existing images are immutable during this flow.
            // Publish only the missing image directory in a same-volume rename.
            try validateOwnedSDK()
            try validateInstalledDependencies(for: packages[0])
            try validateImageAncestors(plan.runtime)
            let destination = sdkRoot.appendingPathComponent(plan.runtime.imagePath, isDirectory: true)
            guard !Self.exists(destination) else { throw AndroidSetupError.existingInstallation(destination.path) }
            try createImageParents(plan.runtime)
            try Self.publishDirectory(stagedSDK.appendingPathComponent(plan.runtime.imagePath), to: destination)
        } else {
            try Data("DroidDock managed Android SDK v1\n".utf8)
                .write(to: stagedSDK.appendingPathComponent(Self.markerName), options: .atomic)
            guard !Self.exists(sdkRoot) else { throw AndroidSetupError.existingInstallation(sdkRoot.path) }
            // Same-volume rename publishes a complete SDK in one filesystem step.
            try Self.publishDirectory(stagedSDK, to: sdkRoot)
        }
        // A completed image is reusable if creating the phone fails. A retry
        // needs no download and never replaces existing phone data.
        progress(.init(message: "Creating your Android phone", fraction: 0.96))
        try Task.checkCancellation()
        try ensureDefaultDevice(version: plan.runtime)
        progress(.init(message: "\(plan.runtime.title) is ready", fraction: 1))
        return sdkRoot
        #endif
    }

    public static func requiredDiskBytes(for plan: AndroidInstallPlan) -> Int64 {
        requiredDiskBytes(downloadBytes: plan.downloadBytes)
    }

    /// Inspect without downloading or changing files. The consent plan retains
    /// all package metadata; only this list is fetched during installation.
    public func packagesToDownload(for plan: AndroidInstallPlan) throws -> [AndroidSDKPackage] {
        try Self.validate(plan: plan)
        guard Self.exists(sdkRoot) else {
            try Self.validateNewPackageDependencies(plan)
            return plan.packages
        }
        try validateOwnedSDK()
        try validateImageAncestors(plan.runtime)
        let image = sdkRoot.appendingPathComponent(plan.runtime.imagePath)
        if Self.exists(image) {
            try Self.validateImage(at: sdkRoot, version: plan.runtime)
            // An already installed API is reused at its installed revision. A
            // newer catalog image must never silently replace its system disk.
            return []
        }
        let package = plan.packages.first { $0.id == plan.runtime.id }!
        try validateInstalledDependencies(for: package)
        return [package]
    }

    public func missingDownloadBytes(for plan: AndroidInstallPlan) throws -> Int64 {
        try packagesToDownload(for: plan).reduce(0) { $0 + $1.archiveBytes }
    }

    public func requiredAdditionalDiskBytes(for plan: AndroidInstallPlan) throws -> Int64 {
        let bytes = try missingDownloadBytes(for: plan)
        if bytes > 0 { return Self.requiredDiskBytes(downloadBytes: bytes) }
        return phoneExists(plan.runtime) ? 0 : 4 * 1_024 * 1_024 * 1_024
    }

    public func isRuntimeInstalled(_ version: AndroidRuntimeVersion) -> Bool {
        do {
            try validateOwnedSDK()
            try validateImageAncestors(version)
            try Self.validateImage(at: sdkRoot, version: version)
            return true
        } catch { return false }
    }

    public func phoneExists(_ version: AndroidRuntimeVersion) -> Bool {
        let device = avdHome.appendingPathComponent(version.deviceName + ".avd", isDirectory: true)
        let index = avdHome.appendingPathComponent(version.deviceName + ".ini")
        guard (try? Self.requireDirectory(avdHome)) != nil, (try? Self.requireDirectory(device)) != nil,
              Self.isRegularFile(device.appendingPathComponent(Self.markerName)),
              Self.isRegularFile(device.appendingPathComponent("config.ini")), Self.isRegularFile(index),
              let path = AVDRepository.readINI(at: index)["path"] else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            == device.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func requiredDiskBytes(downloadBytes: Int64) -> Int64 {
        let gib: Int64 = 1_024 * 1_024 * 1_024
        // Archives, expanded images, and writable virtual-device storage coexist.
        return max(12 * gib, min(downloadBytes, (Int64.max - 4 * gib) / 4) * 4 + 4 * gib)
    }

    static func validate(plan: AndroidInstallPlan) throws {
        let expected = ["emulator": "emulator", "platform-tools": "platform-tools", plan.runtime.id: plan.runtime.imagePath]
        guard AndroidRuntimeVersion(packageID: plan.runtime.id) == plan.runtime else {
            throw AndroidSetupError.invalidPlan("Unsupported Android runtime identifier.")
        }
        guard plan.packages.count == expected.count, Set(plan.packages.map(\.id)) == Set(expected.keys),
              !plan.licenses.isEmpty else { throw AndroidSetupError.invalidPlan("Required Android components or licenses are missing.") }
        var bytes: Int64 = 0
        for package in plan.packages {
            let expectedRoot = package.id.hasPrefix("system-images;") ? "arm64-v8a" : package.id
            guard package.relativeInstallPath == expected[package.id], package.archiveRoot == expectedRoot,
                  isOfficialURL(package.archiveURL), package.archiveBytes > 0,
                  package.archiveBytes < 32 * 1_024 * 1_024 * 1_024 else {
                throw AndroidSetupError.invalidPlan(package.displayName)
            }
            let length = package.checksumType == "sha1" ? 40 : package.checksumType == "sha256" ? 64 : 0
            guard length > 0, package.checksum.count == length,
                  package.checksum.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else {
                throw AndroidSetupError.invalidPlan("Unsupported checksum for \(package.displayName).")
            }
            for (dependency, minimum) in package.minimumDependencies {
                guard expected[dependency] != nil, Self.revisionParts(minimum) != nil else {
                    throw AndroidSetupError.invalidPlan("Unsupported dependency for \(package.displayName).")
                }
            }
            bytes += package.archiveBytes
        }
        guard bytes == plan.downloadBytes,
              Set(plan.licenses.map(\.id)).count == plan.licenses.count,
              plan.licenses.allSatisfy({ !$0.id.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AndroidSetupError.invalidPlan("The license or download size information is incomplete.")
        }
    }

    private static func isOfficialURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "dl.google.com" && url.port == nil
            && url.user == nil && url.password == nil && url.path.hasPrefix("/android/repository/")
    }

    private static func availableBytes(at url: URL) throws -> Int64 {
        if let bytes = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage { return bytes }
        let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let bytes = values[.systemFreeSize] as? NSNumber else {
            throw AndroidSetupError.incompleteInstallation("Could not check free disk space.")
        }
        return bytes.int64Value
    }

    private static func download(package: AndroidSDKPackage, to destination: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7_200
        let delegate = DownloadDelegate(expectedBytes: package.archiveBytes, progress: progress)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (temporary, response) = try await session.download(from: package.archiveURL)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = http.url, isOfficialURL(finalURL) else {
                throw AndroidSetupError.downloadFailed(package.displayName)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    static func verify(archive: URL, package: AndroidSDKPackage) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value == package.archiveBytes else {
            throw AndroidSetupError.checksumMismatch(package.displayName)
        }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            if package.checksumType == "sha1" { sha1.update(data: data) }
            else { sha256.update(data: data) }
        }
        let digest = package.checksumType == "sha1" ? Array(sha1.finalize()) : Array(sha256.finalize())
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        guard hash == package.checksum.lowercased() else { throw AndroidSetupError.checksumMismatch(package.displayName) }
    }

    private static func extract(archive: URL, to destination: URL, archiveRoot: String) async throws {
        let entries = try ZIPDirectory.read(archive)
        try validateArchiveEntries(entries, archiveRoot: archiveRoot)
        for entry in entries where entry.isSymlink {
            try Task.checkCancellation()
            guard entry.size <= 4_096 else { throw AndroidSetupError.unsafeArchive(entry.path) }
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                                                     arguments: ["-p", archive.path, entry.path], timeout: 30)
            try result.requireSuccess(operation: "Read Android archive link")
            guard let target = String(data: result.stdout, encoding: .utf8), !target.isEmpty,
                  !target.hasPrefix("/"), !target.contains("\0"), !target.contains("\\"),
                  isContainedLink(path: entry.path, target: target, root: archiveRoot) else {
                throw AndroidSetupError.unsafeArchive(entry.path)
            }
        }
        // unzip extracts entries from the validated central directory. Some
        // streaming ZIP readers also consume unindexed local records.
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                                                 arguments: ["-q", archive.path, "-d", destination.path], timeout: 1_800)
        try result.requireSuccess(operation: "Unpack Android")
    }

    static func validateArchiveEntries(_ entries: [ZIPDirectory.Entry], archiveRoot: String) throws {
        guard !entries.isEmpty else { throw AndroidSetupError.unsafeArchive("Empty archive") }
        var paths: Set<String> = []
        let links = Set(entries.filter(\.isSymlink).map(\.path))
        for entry in entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            let parts = entry.path.hasSuffix("/") ? Array(components.dropLast()) : components
            guard !parts.isEmpty, parts.first == Substring(archiveRoot),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !entry.path.contains("\\"), !entry.path.contains("\0"),
                  !entry.path.contains(where: { $0.isNewline }), !entry.isSymlink || !entry.path.hasSuffix("/"),
                  paths.insert(parts.joined(separator: "/")).inserted,
                  entry.kind == 0 || entry.kind == 0o100000 || entry.kind == 0o040000 || entry.kind == 0o120000 else {
                throw AndroidSetupError.unsafeArchive(entry.path)
            }
            for length in 1..<parts.count where links.contains(parts.prefix(length).joined(separator: "/")) {
                throw AndroidSetupError.unsafeArchive("An archive member traverses a symbolic link: \(entry.path)")
            }
        }
    }

    private static func isContainedLink(path: String, target: String, root: String) -> Bool {
        let base = URL(fileURLWithPath: "/archive/\(path)").deletingLastPathComponent()
        let resolved = base.appendingPathComponent(target).standardizedFileURL.path
        return resolved == "/archive/\(root)" || resolved.hasPrefix("/archive/\(root)/")
    }

    static func validateExtractedTree(_ directory: URL, archiveRoot: String) throws {
        let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let packageRoot = canonicalDirectory.appendingPathComponent(archiveRoot, isDirectory: true)
        try requireDirectory(packageRoot)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: canonicalDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                              options: [], errorHandler: { _, error in
                                                                  enumerationError = error; return false
                                                              }) else {
            throw AndroidSetupError.unsafeArchive("Could not inspect extracted files")
        }
        let permitted = packageRoot.resolvingSymlinksInPath().standardizedFileURL.path
        for case let item as URL in enumerator {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular || type == .typeSymbolicLink else {
                throw AndroidSetupError.unsafeArchive(item.lastPathComponent)
            }
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == permitted || resolved.hasPrefix(permitted + "/") else {
                throw AndroidSetupError.unsafeArchive(item.lastPathComponent)
            }
        }
        if let enumerationError { throw enumerationError }
    }

    private func validateOwnedSDK() throws {
        try Self.requireDirectory(sdkRoot)
        guard Self.isRegularFile(sdkRoot.appendingPathComponent(Self.markerName)) else {
            throw AndroidSetupError.existingInstallation(sdkRoot.path)
        }
        try Self.validateSharedTools(at: sdkRoot)
    }

    private func validateImageAncestors(_ version: AndroidRuntimeVersion) throws {
        var directory = sdkRoot
        for component in version.imagePath.split(separator: "/") {
            directory.appendPathComponent(String(component), isDirectory: true)
            if Self.exists(directory) { try Self.requireDirectory(directory) }
            else { return }
        }
    }

    private func createImageParents(_ version: AndroidRuntimeVersion) throws {
        var directory = sdkRoot
        for component in version.imagePath.split(separator: "/").dropLast() {
            directory.appendPathComponent(String(component), isDirectory: true)
            try Self.createDirectory(directory)
        }
    }

    private func validateInstalledDependencies(for package: AndroidSDKPackage) throws {
        for (component, minimum) in package.minimumDependencies.sorted(by: { $0.key < $1.key }) {
            guard ["emulator", "platform-tools"].contains(component) else {
                throw AndroidSetupError.invalidPlan("The image requires an unsupported component: \(component).")
            }
            guard Self.revisionParts(minimum)?.contains(where: { $0 != 0 }) == true else { continue }
            let installed = try installedRevision(component: component)
            guard let installed, Self.isRevision(installed, atLeast: minimum) else {
                throw AndroidSetupError.sharedToolsUpdateRequired(component: component, minimum: minimum, installed: installed)
            }
        }
    }

    private static func validateNewPackageDependencies(_ plan: AndroidInstallPlan) throws {
        let packages = Dictionary(uniqueKeysWithValues: plan.packages.map { ($0.id, $0) })
        for package in plan.packages {
            for (component, minimum) in package.minimumDependencies {
                if revisionParts(minimum)?.contains(where: { $0 != 0 }) != true { continue }
                guard let installed = packages[component]?.revision, isRevision(installed, atLeast: minimum) else {
                    throw AndroidSetupError.invalidPlan("The selected \(component) package does not satisfy the image's required revision \(minimum).")
                }
            }
        }
    }

    private func installedRevision(component: String) throws -> String? {
        let package = sdkRoot.appendingPathComponent(component, isDirectory: true)
        let properties = package.appendingPathComponent("source.properties")
        if Self.exists(properties) {
            guard Self.isRegularFile(properties) else { throw AndroidSetupError.incompleteInstallation("Invalid \(component) version metadata.") }
            if let version = AVDRepository.readINI(at: properties)["Pkg.Revision"] { return version }
        }
        let receiptURL = package.appendingPathComponent(".droiddock-package.json")
        if Self.exists(receiptURL) {
            guard Self.isRegularFile(receiptURL),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: receiptURL.path),
                  let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
                throw AndroidSetupError.incompleteInstallation("Invalid \(component) install receipt.")
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let receipt = try? decoder.decode(PackageReceipt.self, from: Data(contentsOf: receiptURL)), receipt.id == component else {
                throw AndroidSetupError.incompleteInstallation("Invalid \(component) install receipt.")
            }
            return receipt.revision.isEmpty ? nil : receipt.revision
        }
        return nil
    }

    private static func revisionParts(_ revision: String) -> [Int]? {
        let fields = revision.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.count <= 4,
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let values = fields.compactMap { Int($0) }
        return values.count == fields.count ? values : nil
    }

    private static func isRevision(_ installed: String, atLeast minimum: String) -> Bool {
        guard var lhs = revisionParts(installed), var rhs = revisionParts(minimum) else { return false }
        let count = max(lhs.count, rhs.count)
        lhs += Array(repeating: 0, count: count - lhs.count)
        rhs += Array(repeating: 0, count: count - rhs.count)
        return !lhs.lexicographicallyPrecedes(rhs)
    }

    private static func validateSDK(at sdk: URL, version: AndroidRuntimeVersion) throws {
        try validateSharedTools(at: sdk)
        try validateImage(at: sdk, version: version)
    }

    private static func validateSharedTools(at sdk: URL) throws {
        try requireDirectory(sdk)
        for component in ["emulator", "platform-tools"] { try requireDirectory(sdk.appendingPathComponent(component)) }
        for path in ["emulator/emulator", "platform-tools/adb"] {
            let url = sdk.appendingPathComponent(path)
            guard isRegularFile(url), FileManager.default.isExecutableFile(atPath: url.path) else {
                throw AndroidSetupError.incompleteInstallation("Missing \(path).")
            }
        }
    }

    private static func validateImage(at sdk: URL, version: AndroidRuntimeVersion) throws {
        let image = sdk.appendingPathComponent(version.imagePath, isDirectory: true)
        try requireDirectory(image)
        for name in ["system.img", "ramdisk.img", "kernel-ranchu"] {
            guard isRegularFile(image.appendingPathComponent(name)) else {
                throw AndroidSetupError.incompleteInstallation("Missing Android image file \(name).")
            }
        }
        guard ["userdata.img", "data/empty_data_disk"].contains(where: { isRegularFile(image.appendingPathComponent($0)) }) else {
            throw AndroidSetupError.incompleteInstallation("Missing Android initial data disk.")
        }
    }

    private struct Acceptance: Codable {
        let acceptedAt: Date
        let licenses: [License]
        struct License: Codable { let id: String; let text: String; let sha256: String }
    }

    private struct PackageReceipt: Codable {
        let id: String
        let revision: String
        let checksum: String
        let checksumType: String
        let archiveURL: String
        let acceptedAt: Date
        let licenses: [Acceptance.License]
    }

    private func writeReceipt(package: AndroidSDKPackage, plan: AndroidInstallPlan, to directory: URL) throws {
        let receipt = PackageReceipt(id: package.id, revision: package.revision, checksum: package.checksum,
                                     checksumType: package.checksumType, archiveURL: package.archiveURL.absoluteString,
                                     acceptedAt: Date(), licenses: plan.licenses.map {
            .init(id: $0.id, text: $0.text,
                  sha256: SHA256.hash(data: Data($0.text.utf8)).map { String(format: "%02x", $0) }.joined())
        })
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: directory.appendingPathComponent(".droiddock-package.json"), options: .atomic)
    }

    private func writeLicenseAcceptance(plan: AndroidInstallPlan, to sdk: URL) throws {
        let record = Acceptance(acceptedAt: Date(), licenses: plan.licenses.map {
            .init(id: $0.id, text: $0.text,
                  sha256: SHA256.hash(data: Data($0.text.utf8)).map { String(format: "%02x", $0) }.joined())
        })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: sdk.appendingPathComponent("droiddock-license-acceptance.json"), options: .atomic)
    }

    private func validatePhoneDestination(_ version: AndroidRuntimeVersion) throws {
        if Self.exists(avdHome) { try Self.requireDirectory(avdHome) }
        let userHome = root.appendingPathComponent("user-home", isDirectory: true)
        if Self.exists(userHome) { try Self.requireDirectory(userHome) }
        let device = avdHome.appendingPathComponent(version.deviceName + ".avd", isDirectory: true)
        let index = avdHome.appendingPathComponent(version.deviceName + ".ini")
        if Self.exists(device) {
            try Self.requireDirectory(device)
            guard Self.isRegularFile(device.appendingPathComponent(Self.markerName)),
                  Self.isRegularFile(device.appendingPathComponent("config.ini")) else {
                throw AndroidSetupError.existingInstallation(device.path)
            }
            if Self.exists(index) {
                guard Self.isRegularFile(index), let path = AVDRepository.readINI(at: index)["path"],
                      URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                        == device.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw AndroidSetupError.existingInstallation(index.path)
                }
            }
        } else if Self.exists(index) { throw AndroidSetupError.existingInstallation(index.path) }
    }

    private func ensureDefaultDevice(version: AndroidRuntimeVersion) throws {
        try validatePhoneDestination(version)
        try Self.createDirectory(avdHome)
        try Self.createDirectory(root.appendingPathComponent("user-home", isDirectory: true))
        let device = avdHome.appendingPathComponent(version.deviceName + ".avd", isDirectory: true)
        let index = avdHome.appendingPathComponent(version.deviceName + ".ini")
        if Self.exists(device) {
            try Self.requireDirectory(device)
            guard Self.isRegularFile(device.appendingPathComponent(Self.markerName)),
                  Self.isRegularFile(device.appendingPathComponent("config.ini")) else {
                throw AndroidSetupError.existingInstallation(device.path)
            }
        } else {
            guard !Self.exists(index) else { throw AndroidSetupError.existingInstallation(index.path) }
            let staging = avdHome.appendingPathComponent(".phone-\(UUID().uuidString)", isDirectory: true)
            try Self.createDirectory(staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            let config = """
            avd.ini.encoding=UTF-8
            avd.ini.displayname=\(version.title) Phone
            abi.type=arm64-v8a
            hw.cpu.arch=arm64
            hw.cpu.ncore=4
            hw.ramSize=2048
            hw.lcd.width=1080
            hw.lcd.height=2400
            hw.lcd.density=420
            hw.keyboard=yes
            hw.mainKeys=no
            hw.gpu.enabled=yes
            hw.gpu.mode=auto
            hw.accelerometer=yes
            hw.sensors.orientation=yes
            hw.audioInput=yes
            hw.battery=yes
            hw.gps=yes
            hw.camera.back=virtualscene
            hw.camera.front=emulated
            disk.dataPartition.size=4G
            image.sysdir.1=\(version.imagePath)/
            tag.id=google_apis
            tag.display=Google APIs
            target=android-\(version.apiLevel)
            PlayStore.enabled=false
            fastboot.forceColdBoot=no
            fastboot.forceFastBoot=yes
            showDeviceFrame=no
            \n
            """
            try Data(config.utf8).write(to: staging.appendingPathComponent("config.ini"), options: .atomic)
            try Data("DroidDock managed virtual phone v1\n".utf8)
                .write(to: staging.appendingPathComponent(Self.markerName), options: .atomic)
            try Self.publishDirectory(staging, to: device)
        }
        if Self.exists(index) {
            try validatePhoneDestination(version)
        } else {
            let contents = "avd.ini.encoding=UTF-8\npath=\(device.path)\ntarget=android-\(version.apiLevel)\n"
            try Data(contents.utf8).write(to: index, options: .atomic)
        }
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func publishDirectory(_ source: URL, to destination: URL) throws {
        // Atomic no-replace rename also protects against a destination appearing
        // after the preflight check, including an empty directory or symlink.
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw AndroidSetupError.existingInstallation(destination.path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    private static func requireDirectory(_ url: URL) throws {
        guard (try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw AndroidSetupError.existingInstallation(url.path)
        }
    }

    private static func createDirectory(_ url: URL) throws {
        if exists(url) { try requireDirectory(url); return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try requireDirectory(url)
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expectedBytes: Int64
        let progress: @Sendable (Double) -> Void
        init(expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
            self.expectedBytes = expectedBytes; self.progress = progress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(min(1, Double(totalBytesWritten) / Double(max(1, expectedBytes))))
            if totalBytesWritten > expectedBytes { downloadTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map { ManagedAndroidRuntime.isOfficialURL($0) } == true ? request : nil)
        }
    }

    private final class InstallationLock {
        private var descriptor: Int32
        init(root: URL) throws {
            descriptor = Darwin.open(root.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor); descriptor = -1
                throw AndroidSetupError.installationInProgress
            }
        }
        func unlock() {
            if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
        }
        deinit { unlock() }
    }
}

/// Reads only ZIP directory metadata, never multi-gigabyte image contents. ZIP64
/// directory fields are supported because Android images can exceed 4 GiB.
enum ZIPDirectory {
    struct Entry {
        let path: String
        let kind: UInt32
        let size: UInt64
        var isSymlink: Bool { kind == 0o120000 }
    }

    static func read(_ archive: URL) throws -> [Entry] {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= 22 else { throw AndroidSetupError.unsafeArchive("Invalid ZIP directory") }
        let tailLength = min(length, 65_557)
        try file.seek(toOffset: length - tailLength)
        let tail = try readExactly(file, count: Int(tailLength))
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail.u32($0) == 0x06054b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
        }), tail.u16(end + 4) == 0, tail.u16(end + 6) == 0 else {
            throw AndroidSetupError.unsafeArchive("Invalid or split ZIP archive")
        }
        var count = UInt64(tail.u16(end + 10))
        var directorySize = UInt64(tail.u32(end + 12))
        var offset = UInt64(tail.u32(end + 16))
        if count == 0xffff || directorySize == 0xffffffff || offset == 0xffffffff {
            let endPosition = length - tailLength + UInt64(end)
            guard endPosition >= 20 else { throw AndroidSetupError.unsafeArchive("Invalid ZIP64 archive") }
            try file.seek(toOffset: endPosition - 20)
            let locator = try readExactly(file, count: 20)
            guard length >= 56, locator.u32(0) == 0x07064b50, locator.u32(4) == 0, locator.u32(16) == 1,
                  locator.u64(8) <= length - 56 else { throw AndroidSetupError.unsafeArchive("Invalid ZIP64 locator") }
            try file.seek(toOffset: locator.u64(8))
            let record = try readExactly(file, count: 56)
            guard record.u32(0) == 0x06064b50, record.u32(16) == 0, record.u32(20) == 0 else {
                throw AndroidSetupError.unsafeArchive("Invalid ZIP64 directory")
            }
            count = record.u64(32); directorySize = record.u64(40); offset = record.u64(48)
        }
        guard count > 0, count <= 100_000, directorySize <= 32 * 1_024 * 1_024,
              offset <= length, directorySize <= length - offset else {
            throw AndroidSetupError.unsafeArchive("Oversized or invalid ZIP directory")
        }
        try file.seek(toOffset: offset)
        let directory = try readExactly(file, count: Int(directorySize))
        var cursor = 0
        var result: [Entry] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor <= directory.count - 46, directory.u32(cursor) == 0x02014b50 else {
                throw AndroidSetupError.unsafeArchive("Truncated ZIP directory")
            }
            let nameLength = Int(directory.u16(cursor + 28))
            let extraLength = Int(directory.u16(cursor + 30))
            let next = cursor + 46 + nameLength + extraLength + Int(directory.u16(cursor + 32))
            guard next <= directory.count, directory.u16(cursor + 8) & 1 == 0,
                  let name = String(data: directory[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else {
                throw AndroidSetupError.unsafeArchive("Unsupported ZIP member")
            }
            var size = UInt64(directory.u32(cursor + 24))
            var compressedSize = UInt64(directory.u32(cursor + 20))
            var localOffset = UInt64(directory.u32(cursor + 42))
            if size == 0xffffffff || compressedSize == 0xffffffff || localOffset == 0xffffffff {
                var extra = cursor + 46 + nameLength
                let extraEnd = extra + extraLength
                var found = false
                while extra + 4 <= extraEnd {
                    let tag = directory.u16(extra), length = Int(directory.u16(extra + 2))
                    guard extra + 4 + length <= extraEnd else { throw AndroidSetupError.unsafeArchive(name) }
                    if tag == 1 {
                        var position = extra + 4
                        let end = position + length
                        for field in 0..<3 {
                            let value = field == 0 ? size : field == 1 ? compressedSize : localOffset
                            if value == 0xffffffff {
                                guard position + 8 <= end else { throw AndroidSetupError.unsafeArchive(name) }
                                let extended = directory.u64(position)
                                if field == 0 { size = extended }
                                else if field == 1 { compressedSize = extended }
                                else { localOffset = extended }
                                position += 8
                            }
                        }
                        found = true; break
                    }
                    extra += 4 + length
                }
                guard found else { throw AndroidSetupError.unsafeArchive(name) }
            }
            // Check both representations before invoking an external extractor;
            // malformed ZIPs can disagree about a member's actual pathname.
            guard offset >= 30, localOffset <= offset - 30 else { throw AndroidSetupError.unsafeArchive(name) }
            try file.seek(toOffset: localOffset)
            let local = try readExactly(file, count: 30)
            let localNameLength = Int(local.u16(26)), localExtraLength = UInt64(local.u16(28))
            let payloadOffset = localOffset + 30 + UInt64(localNameLength) + localExtraLength
            guard local.u32(0) == 0x04034b50, local.u16(6) == directory.u16(cursor + 8),
                  local.u16(8) == directory.u16(cursor + 10), payloadOffset <= offset,
                  compressedSize <= offset - payloadOffset,
                  try readExactly(file, count: localNameLength) == directory[(cursor + 46)..<(cursor + 46 + nameLength)] else {
                throw AndroidSetupError.unsafeArchive(name)
            }
            result.append(.init(path: name, kind: (directory.u32(cursor + 38) >> 16) & 0o170000, size: size))
            cursor = next
        }
        guard cursor == directory.count else { throw AndroidSetupError.unsafeArchive("Unexpected ZIP directory data") }
        return result
    }

    private static func readExactly(_ file: FileHandle, count: Int) throws -> Data {
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw AndroidSetupError.unsafeArchive("Truncated ZIP archive")
        }
        return data
    }
}

private extension Data {
    func u16(_ index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index + 1]) << 8 }
    func u32(_ index: Int) -> UInt32 { UInt32(u16(index)) | UInt32(u16(index + 2)) << 16 }
    func u64(_ index: Int) -> UInt64 { UInt64(u32(index)) | UInt64(u32(index + 4)) << 32 }
}

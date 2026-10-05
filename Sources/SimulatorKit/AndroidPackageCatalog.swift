import Foundation

/// A stable Google APIs ARM64 package identity. Paths and phone names are
/// derived from validated numeric API components, never arbitrary catalog text.
public struct AndroidRuntimeVersion: Hashable, Sendable, Identifiable {
    public let id: String
    public let apiLevel: String
    public let title: String
    public let imagePath: String
    public let deviceName: String
    fileprivate let majorAPI: Int
    fileprivate let minorAPI: Int

    public static let legacy = AndroidRuntimeVersion(packageID: "system-images;android-36;google_apis;arm64-v8a")!

    public init?(packageID: String) {
        let parts = packageID.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "system-images", parts[1].hasPrefix("android-"),
              parts[2] == "google_apis", parts[3] == "arm64-v8a" else { return nil }
        let api = String(parts[1].dropFirst("android-".count))
        guard api.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              api.range(of: #"^[1-9][0-9]{1,3}(?:\.(?:0|[1-9][0-9]{0,2}))?$"#, options: .regularExpression) != nil else { return nil }
        let numbers = api.split(separator: ".").compactMap { Int($0) }
        guard let major = numbers.first, major >= 30 else { return nil }
        id = packageID; apiLevel = api; majorAPI = major; minorAPI = numbers.count > 1 ? numbers[1] : 0
        imagePath = packageID.replacingOccurrences(of: ";", with: "/")
        deviceName = "DroidDock_Phone_API_" + api.replacingOccurrences(of: ".", with: "_")
        let releases = [30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16", 37: "17"]
        title = releases[major].map { "Android \($0) · API \(api)" } ?? "Android API \(api)"
    }

    fileprivate static func newerFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.majorAPI != rhs.majorAPI { return lhs.majorAPI > rhs.majorAPI }
        if lhs.minorAPI != rhs.minorAPI { return lhs.minorAPI > rhs.minorAPI }
        return lhs.apiLevel > rhs.apiLevel
    }
}

public struct AndroidSDKPackage: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let archiveURL: URL
    public let archiveBytes: Int64
    public let checksum: String
    public let checksumType: String
    public let relativeInstallPath: String
    public let archiveRoot: String
    public let revision: String
    public let minimumDependencies: [String: String]

    public init(id: String, displayName: String, archiveURL: URL, archiveBytes: Int64,
                checksum: String, checksumType: String, relativeInstallPath: String, archiveRoot: String,
                revision: String = "", minimumDependencies: [String: String] = [:]) {
        self.id = id; self.displayName = displayName; self.archiveURL = archiveURL
        self.archiveBytes = archiveBytes; self.checksum = checksum; self.checksumType = checksumType
        self.relativeInstallPath = relativeInstallPath; self.archiveRoot = archiveRoot
        self.revision = revision; self.minimumDependencies = minimumDependencies
    }
}

public struct AndroidSDKLicense: Hashable, Sendable, Identifiable {
    public let id: String
    /// Exact XML character content, including leading/trailing whitespace.
    public let text: String

    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct AndroidInstallPlan: Hashable, Sendable {
    public let packages: [AndroidSDKPackage]
    public let licenses: [AndroidSDKLicense]
    public let runtime: AndroidRuntimeVersion
    public var downloadBytes: Int64 { packages.reduce(0) { $0 + $1.archiveBytes } }

    public init(packages: [AndroidSDKPackage], licenses: [AndroidSDKLicense], runtime: AndroidRuntimeVersion = .legacy) {
        self.packages = packages; self.licenses = licenses; self.runtime = runtime
    }
}

/// Reads Google's package manifests. No SDK component is downloaded or installed here.
public enum AndroidPackageCatalog {
    public static let systemImageID = "system-images;android-36;google_apis;arm64-v8a"
    private static let repositoryURL = URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!
    private static let imagesURL = URL(string: "https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml")!
    private static let maximumManifestBytes = 8 * 1_024 * 1_024

    public enum CatalogError: LocalizedError {
        case unsupportedHost
        case invalidCatalog(String)
        case unavailablePackage(String)
        case downloadFailed

        public var errorDescription: String? {
            switch self {
            case .unsupportedHost: return "Android setup currently supports Apple Silicon Macs only."
            case .invalidCatalog(let reason): return "Google's Android package catalog could not be verified: \(reason)"
            case .unavailablePackage(let package): return "Google's catalog has no compatible stable package for \(package). Try again later."
            case .downloadFailed: return "Could not download Google's Android package catalog. Check your connection and try again."
            }
        }
    }

    public static func load() async throws -> AndroidInstallPlan {
        let plans = try await loadAvailable()
        guard let latest = plans.first else { throw CatalogError.unavailablePackage("Android") }
        return latest
    }

    public static func loadAvailable() async throws -> [AndroidInstallPlan] {
        #if os(macOS) && arch(arm64)
        async let repository = fetch(repositoryURL)
        async let images = fetch(imagesURL)
        return try await parseAvailable(repository: repository, systemImages: images)
        #else
        throw CatalogError.unsupportedHost
        #endif
    }

    /// Deterministic parser for the Apple Silicon installation plan, also usable with offline fixtures.
    public static func parse(repository: Data, systemImages: Data) throws -> AndroidInstallPlan {
        let plans = try parseAvailable(repository: repository, systemImages: systemImages)
        guard let latest = plans.first else { throw CatalogError.unavailablePackage("Android") }
        return latest
    }

    /// Stable numeric API versions, newest first. Preview codenames are checked
    /// independently because Google also publishes preview images on channel-0.
    public static func parseAvailable(repository: Data, systemImages: Data) throws -> [AndroidInstallPlan] {
        let tools = try document(repository, rootName: "sdk-repository", namespace: "http://schemas.android.com/sdk/android/repo/repository2/03")
        let images = try document(systemImages, rootName: "sdk-sys-img", namespace: "http://schemas.android.com/sdk/android/repo/sys-img2/03")
        let versions = Set(images.children.compactMap { node -> AndroidRuntimeVersion? in
            guard node.name == "remotePackage", isStable(node), let id = node.attributes["path"] else { return nil }
            return AndroidRuntimeVersion(packageID: id)
        }).sorted(by: AndroidRuntimeVersion.newerFirst)
        guard !versions.isEmpty else { throw CatalogError.unavailablePackage("Android") }
        return try versions.map { try plan(runtime: $0, tools: tools, images: images) }
    }

    private static func plan(runtime: AndroidRuntimeVersion, tools: XMLNode, images: XMLNode) throws -> AndroidInstallPlan {
        let sources: [(String, XMLNode, URL, String)] = [
            ("emulator", tools, repositoryURL.deletingLastPathComponent(), "emulator"),
            ("platform-tools", tools, repositoryURL.deletingLastPathComponent(), "platform-tools"),
            (runtime.id, images, imagesURL.deletingLastPathComponent(), "arm64-v8a")
        ]
        var packages: [AndroidSDKPackage] = []
        var licenses: [AndroidSDKLicense] = []
        var selected: [(XMLNode, Revision)] = []
        for (id, source, baseURL, archiveRoot) in sources {
            let candidates = try source.children.filter {
                $0.name == "remotePackage" && $0.attributes["path"] == id && isStable($0)
            }.map { ($0, try revision($0.child("revision"))) }.sorted { $0.1 > $1.1 }
            guard let (node, version) = candidates.first(where: { compatibleArchive($0.0, packageID: id) != nil }),
                  let archive = compatibleArchive(node, packageID: id), let complete = archive.child("complete") else {
                throw CatalogError.unavailablePackage(id)
            }
            if id == runtime.id { try validateImageMetadata(node, runtime: runtime) }
            let name = try requiredText(node, "display-name")
            guard let size = Int64(try requiredText(complete, "size")), size > 0, size <= 20 * 1_024 * 1_024 * 1_024 else {
                throw CatalogError.invalidCatalog("invalid download size for \(id)")
            }
            guard let digest = complete.child("checksum"), let algorithm = digest.attributes["type"]?.lowercased(),
                  ["sha1", "sha256"].contains(algorithm) else {
                throw CatalogError.invalidCatalog("missing or unsupported checksum for \(id)")
            }
            let checksum = digest.trimmed.lowercased()
            guard checksum.count == (algorithm == "sha1" ? 40 : 64),
                  checksum.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
                throw CatalogError.invalidCatalog("invalid checksum for \(id)")
            }
            let url = try archiveURL(try requiredText(complete, "url"), baseURL: baseURL)
            let references = node.children.filter { $0.name == "uses-license" }
            guard !references.isEmpty else { throw CatalogError.invalidCatalog("missing license for \(id)") }
            for reference in references {
                guard let licenseID = reference.attributes["ref"], !licenseID.isEmpty,
                      let licenseNode = source.children.first(where: { $0.name == "license" && $0.attributes["id"] == licenseID }),
                      !licenseNode.trimmed.isEmpty, licenseNode.children.isEmpty else {
                    throw CatalogError.invalidCatalog("missing license text for \(id)")
                }
                let license = AndroidSDKLicense(id: licenseID, text: licenseNode.text)
                if let existing = licenses.first(where: { $0.id == licenseID }) {
                    guard existing == license else { throw CatalogError.invalidCatalog("conflicting license text for \(licenseID)") }
                } else { licenses.append(license) }
            }
            packages.append(AndroidSDKPackage(id: id, displayName: name, archiveURL: url, archiveBytes: size,
                                              checksum: checksum, checksumType: algorithm,
                                              relativeInstallPath: id.replacingOccurrences(of: ";", with: "/"), archiveRoot: archiveRoot,
                                              revision: version.description, minimumDependencies: try dependencies(node)))
            selected.append((node, version))
        }
        for (node, _) in selected {
            for dependency in node.child("dependencies")?.children.filter({ $0.name == "dependency" }) ?? [] {
                guard let id = dependency.attributes["path"],
                      let available = selected.first(where: { $0.0.attributes["path"] == id }) else {
                    throw CatalogError.invalidCatalog("a package needs an unsupported additional component")
                }
                if let minimum = dependency.child("min-revision"), available.1 < (try revision(minimum)) {
                    throw CatalogError.invalidCatalog("the selected \(id) version is too old")
                }
            }
        }
        return AndroidInstallPlan(packages: packages, licenses: licenses, runtime: runtime)
    }

    private static func isStable(_ node: XMLNode) -> Bool {
        node.attributes["obsolete"] != "true" && node.child("channelRef")?.attributes["ref"] == "channel-0"
            && node.child("revision")?.child("preview") == nil
            && !(node.child("type-details")?.children.contains(where: { $0.name == "codename" && !$0.trimmed.isEmpty }) ?? false)
    }

    private static func validateImageMetadata(_ node: XMLNode, runtime: AndroidRuntimeVersion) throws {
        guard let details = node.child("type-details"), details.child("abi")?.trimmed == "arm64-v8a",
              let api = details.child("api-level")?.trimmed,
              let metadataVersion = AndroidRuntimeVersion(packageID: "system-images;android-\(api);google_apis;arm64-v8a"),
              metadataVersion.majorAPI == runtime.majorAPI, metadataVersion.minorAPI == runtime.minorAPI,
              details.children.contains(where: { $0.name == "tag" && $0.child("id")?.trimmed == "google_apis" }) else {
            throw CatalogError.invalidCatalog("system-image metadata does not match \(runtime.id)")
        }
    }

    private static func dependencies(_ node: XMLNode) throws -> [String: String] {
        var result: [String: String] = [:]
        for dependency in node.child("dependencies")?.children.filter({ $0.name == "dependency" }) ?? [] {
            guard let id = dependency.attributes["path"], !id.isEmpty, result[id] == nil else {
                throw CatalogError.invalidCatalog("invalid or duplicate dependency")
            }
            result[id] = try dependency.child("min-revision").map { try revision($0).description } ?? "0"
        }
        return result
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: OfficialCatalogRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, isOfficialURL(finalURL),
              response.expectedContentLength <= Int64(maximumManifestBytes) else { throw CatalogError.downloadFailed }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumManifestBytes else { throw CatalogError.invalidCatalog("manifest is too large") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    fileprivate static func isOfficialURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "dl.google.com" && url.port == nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil && url.path.hasPrefix("/android/repository/")
            && !url.absoluteString.contains("%") && !url.absoluteString.contains("\\")
            && !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private static func archiveURL(_ text: String, baseURL: URL) throws -> URL {
        guard !text.contains("%"), !text.contains("\\"), !text.hasPrefix("/"),
              !text.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let url = URL(string: text, relativeTo: baseURL.appendingPathComponent(""))?.absoluteURL,
              isOfficialURL(url), url.pathExtension == "zip" else {
            throw CatalogError.invalidCatalog("untrusted archive URL")
        }
        return url
    }

    private static func compatibleArchive(_ node: XMLNode, packageID: String) -> XMLNode? {
        let compatible = node.child("archives")?.children.filter { archive in
            guard archive.name == "archive", archive.child("complete") != nil else { return false }
            let host = archive.child("host-os")?.trimmed
            let architecture = archive.child("host-arch")?.trimmed
            let bits = archive.child("host-bits")?.trimmed
            guard bits == nil || bits == "64" else { return false }
            if AndroidRuntimeVersion(packageID: packageID) != nil { return host == nil && architecture == nil }
            guard host == "macosx" else { return false }
            if architecture == "aarch64" || architecture == "arm64" { return true }
            return packageID == "platform-tools" && architecture == nil
        } ?? []
        return compatible.first(where: { $0.child("host-arch") != nil }) ?? compatible.first
    }

    private struct Revision: Comparable {
        let major: Int; let minor: Int; let micro: Int
        var description: String { "\(major).\(minor).\(micro)" }
        static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor, lhs.micro) < (rhs.major, rhs.minor, rhs.micro) }
    }

    private static func revision(_ node: XMLNode?) throws -> Revision {
        guard let node else { throw CatalogError.invalidCatalog("missing package revision") }
        func number(_ name: String, required: Bool = false) throws -> Int {
            guard let text = node.child(name)?.trimmed else {
                if required { throw CatalogError.invalidCatalog("missing revision number") }
                return 0
            }
            guard let value = Int(text), value >= 0 else { throw CatalogError.invalidCatalog("invalid package revision") }
            return value
        }
        return try Revision(major: number("major", required: true), minor: number("minor"), micro: number("micro"))
    }

    private static func requiredText(_ node: XMLNode, _ name: String) throws -> String {
        guard let value = node.child(name)?.trimmed, !value.isEmpty else { throw CatalogError.invalidCatalog("missing \(name)") }
        return value
    }

    private static func document(_ data: Data, rootName: String, namespace: String) throws -> XMLNode {
        guard !data.isEmpty, data.count <= maximumManifestBytes else { throw CatalogError.invalidCatalog("invalid manifest size") }
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), !builder.rejected, let root = builder.root,
              root.name == rootName, root.namespace == namespace else {
            throw CatalogError.invalidCatalog("malformed or unsupported XML")
        }
        var licenseIDs = Set<String>()
        for license in root.children where license.name == "license" {
            guard let id = license.attributes["id"], !id.isEmpty, licenseIDs.insert(id).inserted else {
                throw CatalogError.invalidCatalog("duplicate or missing license identifier")
            }
        }
        return root
    }
}

private final class OfficialCatalogRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(AndroidPackageCatalog.isOfficialURL) == true ? request : nil)
    }
}

private final class XMLNode {
    let name: String
    let namespace: String?
    let attributes: [String: String]
    var children: [XMLNode] = []
    var text = ""
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    init(name: String, namespace: String?, attributes: [String: String]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes
    }
    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var rejected = false
    private var stack: [XMLNode] = []
    private var count = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 64, count <= 100_000 else { rejected = true; parser.abortParsing(); return }
        let node = XMLNode(name: elementName, namespace: namespaceURI, attributes: attributes)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { rejected = true; parser.abortParsing(); return }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { rejected = true; parser.abortParsing(); return }
        stack.last?.text += text
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { rejected = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { rejected = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { rejected = true; parser.abortParsing(); return nil }
}

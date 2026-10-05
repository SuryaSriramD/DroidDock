import Foundation

/// Stable numeric app versions. Missing components compare as zero; preview
/// labels are deliberately excluded from the public stable-release channel.
public struct AppReleaseVersion: Equatable, Comparable, Sendable {
    public let description: String
    private let components: [Int]

    public init?(_ value: String) {
        let numeric = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count), pieces.allSatisfy({ part in
            !part.isEmpty && part.count <= 9 && part.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == pieces.count else { return nil }
        components = numbers + Array(repeating: 0, count: 4 - numbers.count)
        description = numeric
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.components == rhs.components }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

public struct AppReleaseUpdate: Equatable, Sendable {
    public let version: String
    public let releaseURL: URL
    public let downloadURL: URL?
}

public enum AppReleaseCheckResult: Equatable, Sendable {
    case available(AppReleaseUpdate)
    case upToDate(latestVersion: String)
    case newerLocalBuild(latestVersion: String)
}

public enum AppReleaseCheckError: LocalizedError, Equatable {
    case unknownInstalledVersion
    case invalidRelease
    case noPublicRelease
    case rateLimited
    case responseTooLarge
    case unexpectedStatus(Int)
    case offline
    case timedOut
    case connectionFailed

    public var errorDescription: String? {
        switch self {
        case .unknownInstalledVersion: return "This build does not report a stable app version, so DroidDock cannot compare it with public releases."
        case .invalidRelease: return "GitHub returned release information that could not be verified. No download was opened."
        case .noPublicRelease: return "No stable DroidDock release is available yet. Preview releases are not included in app update checks."
        case .rateLimited: return "GitHub's update service has reached its request limit. Try again later."
        case .responseTooLarge: return "GitHub's release response was too large to verify. Try again later."
        case .unexpectedStatus(let status): return "GitHub's update service returned HTTP \(status). Try again later."
        case .offline: return "Updates could not be checked because this Mac is offline. Connect to the internet and try again."
        case .timedOut: return "The update check timed out. Try again when your connection is available."
        case .connectionFailed: return "DroidDock could not connect to GitHub to check for updates. Try again later."
        }
    }
}

/// A small transport value makes the HTTP/error contract testable without a
/// network connection. Only the pinned GitHub repository may supply updates.
public struct AppReleaseResponse: Sendable {
    public let url: URL
    public let status: Int
    public let headers: [String: String]
    public let data: Data

    public init(url: URL, status: Int, headers: [String: String] = [:], data: Data) {
        self.url = url; self.status = status; self.headers = headers; self.data = data
    }
}

public enum AppReleaseUpdater {
    public static let repositoryURL = URL(string: "https://github.com/SuryaSriramD/DroidDock")!
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/SuryaSriramD/DroidDock/releases/latest")!
    public static let maximumResponseBytes = 1_048_576
    public typealias Loader = @Sendable (URLRequest) async throws -> AppReleaseResponse

    public static func check(installedVersion: String) async throws -> AppReleaseCheckResult {
        try await check(installedVersion: installedVersion, load: { try await fetch($0) })
    }

    public static func check(installedVersion: String, load: Loader) async throws -> AppReleaseCheckResult {
        guard AppReleaseVersion(installedVersion) != nil else { throw AppReleaseCheckError.unknownInstalledVersion }
        var request = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DroidDock-App-Update-Check", forHTTPHeaderField: "User-Agent")
        do {
            try Task.checkCancellation()
            let response = try await load(request)
            try Task.checkCancellation()
            return try evaluate(response, installedVersion: installedVersion)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let network = error as? URLError {
                switch network.code {
                case .notConnectedToInternet, .dataNotAllowed, .networkConnectionLost: throw AppReleaseCheckError.offline
                case .timedOut: throw AppReleaseCheckError.timedOut
                default: throw AppReleaseCheckError.connectionFailed
                }
            }
            throw error
        }
    }

    public static func evaluate(_ response: AppReleaseResponse, installedVersion: String) throws -> AppReleaseCheckResult {
        guard let installed = AppReleaseVersion(installedVersion) else { throw AppReleaseCheckError.unknownInstalledVersion }
        guard response.url.absoluteString == latestReleaseAPI.absoluteString else { throw AppReleaseCheckError.invalidRelease }
        guard response.data.count <= maximumResponseBytes else { throw AppReleaseCheckError.responseTooLarge }
        let remaining = response.headers.first { $0.key.lowercased() == "x-ratelimit-remaining" }?.value
        if response.status == 429 || (response.status == 403 && remaining == "0") { throw AppReleaseCheckError.rateLimited }
        if response.status == 404 { throw AppReleaseCheckError.noPublicRelease }
        guard response.status == 200 else { throw AppReleaseCheckError.unexpectedStatus(response.status) }
        guard let release = try? JSONDecoder().decode(Release.self, from: response.data),
              !release.draft, !release.prerelease, let latest = AppReleaseVersion(release.tag_name) else {
            throw AppReleaseCheckError.invalidRelease
        }
        let expectedRelease = repositoryURL.appendingPathComponent("releases/tag/" + release.tag_name)
        guard release.html_url == expectedRelease.absoluteString else { throw AppReleaseCheckError.invalidRelease }
        let candidates = release.assets.filter { $0.name == "DroidDock-macOS.dmg" }
        guard candidates.count <= 1 else { throw AppReleaseCheckError.invalidRelease }
        var download: URL?
        if let asset = candidates.first {
            let expected = repositoryURL.appendingPathComponent("releases/download/" + release.tag_name + "/DroidDock-macOS.dmg")
            guard asset.browser_download_url == expected.absoluteString else { throw AppReleaseCheckError.invalidRelease }
            if asset.state == "uploaded" { download = expected }
        }
        if latest > installed {
            return .available(AppReleaseUpdate(version: latest.description, releaseURL: expectedRelease, downloadURL: download))
        }
        if installed > latest { return .newerLocalBuild(latestVersion: latest.description) }
        return .upToDate(latestVersion: latest.description)
    }

    /// Downloads metadata only. Browser navigation to a verified release or DMG
    /// is an explicit user action; this service never installs app binaries.
    private static func fetch(_ request: URLRequest) async throws -> AppReleaseResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: PinnedReleaseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url,
              url.absoluteString == latestReleaseAPI.absoluteString else { throw AppReleaseCheckError.invalidRelease }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw AppReleaseCheckError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw AppReleaseCheckError.responseTooLarge }
            data.append(byte)
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String { result[key.lowercased()] = String(describing: pair.value) }
        }
        return AppReleaseResponse(url: url, status: response.statusCode, headers: headers, data: data)
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let state: String
        }
    }
}

private final class PinnedReleaseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.absoluteString == AppReleaseUpdater.latestReleaseAPI.absoluteString ? request : nil)
    }
}

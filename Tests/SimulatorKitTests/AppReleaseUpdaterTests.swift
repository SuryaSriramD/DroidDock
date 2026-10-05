import XCTest
@testable import SimulatorKit

final class AppReleaseUpdaterTests: XCTestCase {
    func testVersionsCompareNumericallyWithoutDowngradingNewerLocalBuild() throws {
        XCTAssertGreaterThan(try XCTUnwrap(AppReleaseVersion("0.10.0")), try XCTUnwrap(AppReleaseVersion("0.9.9")))
        XCTAssertEqual(AppReleaseVersion("v1.2"), AppReleaseVersion("1.2.0.0"))
        XCTAssertEqual(try AppReleaseUpdater.evaluate(response(tag: "v0.2.1"), installedVersion: "0.3.2"),
                       .newerLocalBuild(latestVersion: "0.2.1"))
        XCTAssertEqual(try AppReleaseUpdater.evaluate(response(tag: "v0.3.2"), installedVersion: "0.3.2"),
                       .upToDate(latestVersion: "0.3.2"))
    }

    func testRejectsPreviewAndMalformedVersionStrings() {
        for value in ["", "v", "1..2", "1.2.", "1.0-rc.1", "1.0+build", " 1.2", "-1.2", "1/2", "1.2.3.4.5", "999999999999.1"] {
            XCTAssertNil(AppReleaseVersion(value), value)
        }
    }

    func testNewerStableReleaseProvidesOnlyPinnedInstallerAndReleaseURLs() throws {
        let result = try AppReleaseUpdater.evaluate(response(tag: "v0.4.0"), installedVersion: "0.3.2")
        guard case .available(let update) = result else { return XCTFail("Expected a newer app release") }
        XCTAssertEqual(update.version, "0.4.0")
        XCTAssertEqual(update.releaseURL.absoluteString, "https://github.com/SuryaSriramD/DroidDock/releases/tag/v0.4.0")
        XCTAssertEqual(update.downloadURL?.absoluteString, "https://github.com/SuryaSriramD/DroidDock/releases/download/v0.4.0/DroidDock-macOS.dmg")
    }

    func testDraftsAndPrereleasesAreNeverOffered() throws {
        let alterations: [[String: Any]] = [["draft": true], ["prerelease": true], ["tag_name": "v0.4.0-beta"]]
        for changes in alterations {
            XCTAssertThrowsError(try AppReleaseUpdater.evaluate(response(changes: changes), installedVersion: "0.3.2")) {
                XCTAssertEqual($0 as? AppReleaseCheckError, .invalidRelease)
            }
        }
    }

    func testUntrustedDownloadTargetsAreRejected() throws {
        for target in [
            "http://github.com/SuryaSriramD/DroidDock/releases/download/v0.4.0/DroidDock-macOS.dmg",
            "https://example.com/DroidDock-macOS.dmg",
            "https://github.com/OtherOwner/DroidDock/releases/download/v0.4.0/DroidDock-macOS.dmg",
            "https://github.com/SuryaSriramD/OtherRepo/releases/download/v0.4.0/DroidDock-macOS.dmg",
            "https://github.com/SuryaSriramD/DroidDock/releases/download/v0.2.1/DroidDock-macOS.dmg",
            "https://github.com/SuryaSriramD/DroidDock/releases/download/v0.4.0/DroidDock-macOS.dmg?redirect=elsewhere",
            "https://github.com@evil.example/SuryaSriramD/DroidDock/releases/download/v0.4.0/DroidDock-macOS.dmg"
        ] {
            let payload = try response(changes: ["assets": [["name": "DroidDock-macOS.dmg", "state": "uploaded", "browser_download_url": target]]])
            XCTAssertThrowsError(try AppReleaseUpdater.evaluate(payload, installedVersion: "0.3.2"), target) {
                XCTAssertEqual($0 as? AppReleaseCheckError, .invalidRelease)
            }
        }
    }

    func testUntrustedReleasePageAndAmbiguousInstallerAreRejected() throws {
        XCTAssertThrowsError(try AppReleaseUpdater.evaluate(response(changes: ["html_url": "https://github.com/OtherOwner/DroidDock/releases/tag/v0.4.0"]), installedVersion: "0.3.2"))
        let asset = asset(tag: "v0.4.0")
        XCTAssertThrowsError(try AppReleaseUpdater.evaluate(response(changes: ["assets": [asset, asset]]), installedVersion: "0.3.2"))
    }

    func testReleaseWithoutUploadedStandardInstallerCanOnlyOpenReleasePage() throws {
        let variants: [[[String: String]]] = [[], [["name": "DroidDock-macOS.dmg", "state": "new", "browser_download_url": asset(tag: "v0.4.0")["browser_download_url"]!]],
                                              [["name": "Unexpected.dmg", "state": "uploaded", "browser_download_url": "https://example.com/Unexpected.dmg"]]]
        for assets in variants {
            let result = try AppReleaseUpdater.evaluate(response(changes: ["assets": assets]), installedVersion: "0.3.2")
            guard case .available(let release) = result else { return XCTFail("Expected release details") }
            XCTAssertNil(release.downloadURL)
            XCTAssertEqual(release.releaseURL.host, "github.com")
        }
    }

    func testHTTPFailuresAreNotReportedAsUpToDate() throws {
        let cases: [(Int, [String: String], AppReleaseCheckError)] = [
            (404, [:], .noPublicRelease), (429, [:], .rateLimited),
            (403, ["X-RateLimit-Remaining": "0"], .rateLimited),
            (403, [:], .unexpectedStatus(403)), (503, [:], .unexpectedStatus(503))
        ]
        for (status, headers, expected) in cases {
            let result = AppReleaseResponse(url: AppReleaseUpdater.latestReleaseAPI, status: status, headers: headers, data: Data())
            XCTAssertThrowsError(try AppReleaseUpdater.evaluate(result, installedVersion: "0.3.2")) {
                XCTAssertEqual($0 as? AppReleaseCheckError, expected)
            }
        }
    }

    func testBoundedBodyAndPinnedResponseLocation() throws {
        let valid = try response()
        let responses = [
            AppReleaseResponse(url: URL(string: "https://api.github.com/repos/OtherOwner/DroidDock/releases/latest")!, status: 200, data: valid.data),
            AppReleaseResponse(url: AppReleaseUpdater.latestReleaseAPI, status: 200, data: Data("not JSON".utf8))
        ]
        for response in responses {
            XCTAssertThrowsError(try AppReleaseUpdater.evaluate(response, installedVersion: "0.3.2")) {
                XCTAssertEqual($0 as? AppReleaseCheckError, .invalidRelease)
            }
        }
        let huge = AppReleaseResponse(url: AppReleaseUpdater.latestReleaseAPI, status: 200,
                                      data: Data(repeating: 32, count: AppReleaseUpdater.maximumResponseBytes + 1))
        XCTAssertThrowsError(try AppReleaseUpdater.evaluate(huge, installedVersion: "0.3.2")) {
            XCTAssertEqual($0 as? AppReleaseCheckError, .responseTooLarge)
        }
    }

    func testRequestUsesPublicPinnedAPIAndBoundedTimeout() async throws {
        let payload = try response(tag: "v0.3.2")
        let result = try await AppReleaseUpdater.check(installedVersion: "0.3.2", load: { request in
            XCTAssertEqual(request.url, AppReleaseUpdater.latestReleaseAPI)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return payload
        })
        XCTAssertEqual(result, .upToDate(latestVersion: "0.3.2"))
    }

    func testNetworkFailuresAndUnknownLocalVersionRemainFailures() async throws {
        let cases: [(URLError.Code, AppReleaseCheckError)] = [(.notConnectedToInternet, .offline), (.timedOut, .timedOut), (.cannotFindHost, .connectionFailed)]
        for (code, expected) in cases {
            do {
                _ = try await AppReleaseUpdater.check(installedVersion: "0.3.2", load: { _ in throw URLError(code) })
                XCTFail("Expected a failed check")
            } catch { XCTAssertEqual(error as? AppReleaseCheckError, expected) }
        }
        do {
            _ = try await AppReleaseUpdater.check(installedVersion: "Development build", load: { _ in
                XCTFail("Unknown installed version must not initiate a network request")
                throw URLError(.badURL)
            })
            XCTFail("Expected unknown-version error")
        } catch { XCTAssertEqual(error as? AppReleaseCheckError, .unknownInstalledVersion) }
    }

    private func response(tag: String = "v0.4.0", changes: [String: Any] = [:]) throws -> AppReleaseResponse {
        var json: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false,
                                   "html_url": "https://github.com/SuryaSriramD/DroidDock/releases/tag/\(tag)",
                                   "assets": [asset(tag: tag)]]
        json.merge(changes) { _, replacement in replacement }
        return AppReleaseResponse(url: AppReleaseUpdater.latestReleaseAPI, status: 200,
                                  data: try JSONSerialization.data(withJSONObject: json))
    }

    private func asset(tag: String) -> [String: String] {
        ["name": "DroidDock-macOS.dmg", "state": "uploaded",
         "browser_download_url": "https://github.com/SuryaSriramD/DroidDock/releases/download/\(tag)/DroidDock-macOS.dmg"]
    }
}

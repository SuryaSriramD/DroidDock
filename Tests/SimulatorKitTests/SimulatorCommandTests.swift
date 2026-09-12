import Foundation
import XCTest
@testable import SimulatorKit

final class SimulatorCommandTests: XCTestCase {
    private func store() throws -> SimulatorCommandStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Simulator Command Tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SimulatorCommandStore(directory: root.appendingPathComponent("Commands", isDirectory: true))
    }

    private func path(_ store: SimulatorCommandStore, _ id: UUID, _ suffix: String = "request.json") -> URL {
        store.directory.appendingPathComponent("\(id.uuidString).\(suffix)")
    }

    private func raw(_ data: Data, at url: URL, permissions: Int = 0o600) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func testRequestResponseRoundTripUsesOwnerOnlyFilesAndCleansUp() throws {
        let mailbox = try store(), request = SimulatorCommandRequest(action: .boot, device: "Pixel 10 Pro")
        try mailbox.createRequest(request)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: mailbox.directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path(mailbox, request.id).path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNil(try mailbox.readResponse(id: request.id))
        XCTAssertEqual(try mailbox.consumeRequest(id: request.id), request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(mailbox, request.id).path))
        XCTAssertThrowsError(try mailbox.consumeRequest(id: request.id))
        let device = SimulatorCommandDevice(id: "Pixel_10_Pro", name: "Pixel 10 Pro", state: "running", serial: "emulator-5554", pid: 123, sdkPath: "/sdk", isOwned: true)
        let response = SimulatorCommandResponse(id: request.id, success: true, message: "Ready", devices: [device])
        try mailbox.writeResponse(response)
        XCTAssertEqual(try mailbox.readResponse(id: request.id), response)
        try mailbox.remove(id: request.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mailbox.directory.path), [])
        XCTAssertThrowsError(try mailbox.writeResponse(response), "A late GUI response must not recreate files after client cleanup")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mailbox.directory.path), [])
    }

    func testUnknownAndExpiredURLsCannotCreateClaims() throws {
        let mailbox = try store()
        XCTAssertThrowsError(try mailbox.consumeRequest(id: UUID()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mailbox.directory.path), [])
        let now = Date(), request = SimulatorCommandRequest(action: .boot, timeout: 1, createdAt: now)
        try mailbox.createRequest(request, now: now)
        XCTAssertThrowsError(try mailbox.consumeRequest(id: request.id, now: now.addingTimeInterval(2))) { error in
            guard case SimulatorCommandError.expired = error else { return XCTFail("Expected expiration, received \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mailbox.directory.path), [path(mailbox, request.id).lastPathComponent])
    }

    func testURLRoutingRejectsPathsCredentialsEncodedNamesAndExtraParameters() {
        let id = UUID(), valid = SimulatorCommandStore.commandURL(id: id)
        XCTAssertEqual(valid.scheme, "droiddock")
        XCTAssertEqual(SimulatorCommandStore.requestID(from: valid), id)
        let legacy = SimulatorCommandStore.compatibleCommandURL(id: id, registeredSchemes: ["android-simulator"])
        XCTAssertEqual(legacy?.scheme, "android-simulator")
        XCTAssertEqual(legacy.flatMap { SimulatorCommandStore.requestID(from: $0) }, id)
        XCTAssertEqual(SimulatorCommandStore.compatibleCommandURL(id: id, registeredSchemes: ["android-simulator", "droiddock"]), valid)
        XCTAssertNil(SimulatorCommandStore.compatibleCommandURL(id: id, registeredSchemes: ["unrelated"]))
        for value in ["https://command/\(id)", "android-simulator://other/\(id)", "android-simulator://user@command/\(id)",
                      "android-simulator://command:42/\(id)", "android-simulator://command/../\(id)",
                      "android-simulator://command/\(id)?path=/tmp/evil", "android-simulator://command/\(id)#extra",
                      "android-simulator://command/%41\(id.uuidString.dropFirst())", "android-simulator://command/invalid"] {
            XCTAssertNil(SimulatorCommandStore.requestID(from: URL(string: value)!), value)
            let renamed = value.replacingOccurrences(of: "android-simulator://", with: "droiddock://")
            XCTAssertNil(SimulatorCommandStore.requestID(from: URL(string: renamed)!), renamed)
        }
    }

    func testUnsafeSymlinkHardlinkPermissionsAndOversizeRequestsAreRejected() throws {
        let mailbox = try store(), request = SimulatorCommandRequest(action: .list)
        try mailbox.createRequest(request)
        let requestURL = path(mailbox, request.id), outside = mailbox.directory.deletingLastPathComponent().appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: requestURL, to: outside)
        try FileManager.default.createSymbolicLink(at: requestURL, withDestinationURL: outside)
        XCTAssertThrowsError(try mailbox.consumeRequest(id: request.id))
        try FileManager.default.removeItem(at: requestURL)
        try FileManager.default.linkItem(at: outside, to: requestURL)
        XCTAssertThrowsError(try mailbox.consumeRequest(id: request.id))
        try FileManager.default.removeItem(at: requestURL)
        try raw(try Data(contentsOf: outside), at: requestURL, permissions: 0o644)
        XCTAssertThrowsError(try mailbox.consumeRequest(id: request.id))
        try raw(Data(repeating: 32, count: SimulatorCommandStore.maximumFileBytes + 1), at: requestURL)
        XCTAssertThrowsError(try mailbox.consumeRequest(id: request.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mailbox.directory.path), [requestURL.lastPathComponent])
        XCTAssertEqual(try JSONDecoder().decode(SimulatorCommandRequest.self, from: Data(contentsOf: outside)), request)
    }

    func testRequestIDMismatchAndResponseIDMismatchAreRejected() throws {
        let mailbox = try store(), request = SimulatorCommandRequest(action: .list)
        try mailbox.createRequest(request)
        try raw(JSONEncoder().encode(SimulatorCommandRequest(action: .list)), at: path(mailbox, request.id))
        XCTAssertThrowsError(try mailbox.consumeRequest(id: request.id))
        try raw(JSONEncoder().encode(SimulatorCommandResponse(id: UUID(), success: true, message: "Wrong reply")), at: path(mailbox, request.id, "response.json"))
        XCTAssertThrowsError(try mailbox.readResponse(id: request.id))
    }

    func testConcurrentDeliveryClaimsAtMostOnceAndCleanupPreventsLateResponses() async throws {
        let mailbox = try store(), request = SimulatorCommandRequest(action: .list)
        try mailbox.createRequest(request)
        let successes = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<12 {
                group.addTask { (try? mailbox.consumeRequest(id: request.id)) == nil ? 0 : 1 }
            }
            var total = 0
            for await value in group { total += value }
            return total
        }
        XCTAssertEqual(successes, 1)
        try mailbox.remove(id: request.id)
        for _ in 0..<20 {
            let raced = SimulatorCommandRequest(action: .status)
            try mailbox.createRequest(raced)
            _ = try mailbox.consumeRequest(id: raced.id)
            let response = SimulatorCommandResponse(id: raced.id, success: true, message: "Done")
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? mailbox.writeResponse(response) }
                group.addTask { try? mailbox.remove(id: raced.id) }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mailbox.directory.path), [])
        }
    }

    func testInsecureOrSymlinkedCommandDirectoryIsRejected() throws {
        let mailbox = try store(), request = SimulatorCommandRequest(action: .list)
        try FileManager.default.createDirectory(at: mailbox.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try mailbox.createRequest(request))
        try FileManager.default.removeItem(at: mailbox.directory)
        let other = mailbox.directory.deletingLastPathComponent().appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: mailbox.directory, withDestinationURL: other)
        XCTAssertThrowsError(try mailbox.createRequest(request))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
    }

    func testParserPreservesSpacedPathsDeepLinksAndDefaultOpenSemantics() throws {
        let root = URL(fileURLWithPath: "/tmp/test project", isDirectory: true)
        let options = try SimulatorCLIOptions.parse(["--app", "/Applications/DroidDock.app", "install", "Pixel 10 Pro", "build output/dev.apk", "--json"])
        let request = try options.makeRequest(currentDirectory: root)
        XCTAssertEqual(request.device, "Pixel 10 Pro")
        XCTAssertEqual(request.argument, "/tmp/test project/build output/dev.apk")
        XCTAssertTrue(options.json)
        XCTAssertEqual(options.appPath, "/Applications/DroidDock.app")
        let deepLink = "exp://192.168.1.20:8081/--/route?first=one&second=two"
        XCTAssertEqual(try SimulatorCLIOptions.parse(["open-url", "Pixel", deepLink]).makeRequest(currentDirectory: root).argument, deepLink)
        XCTAssertNil(try SimulatorCLIOptions.parse(["open"]).makeRequest(currentDirectory: root).device)
        XCTAssertTrue(try SimulatorCLIOptions.parse([]).showHelp)
        XCTAssertTrue(try SimulatorCLIOptions.parse(["--version"]).showVersion)
        XCTAssertEqual(try SimulatorCLIOptions.parse(["boot", "--timeout", "45", "--", "-Device"]).device, "-Device")
    }

    func testParserAndRequestRejectInvalidOperationsArgumentsTimeoutsAndDeepLinks() throws {
        for arguments in [["wipe", "Pixel"], ["stop"], ["list", "Pixel"], ["boot", "one", "two"], ["--app"],
                          ["boot", "--timeout", "NaN"], ["boot", "--timeout", "601"], ["--unknown"], ["install", "Pixel"]] {
            XCTAssertThrowsError(try SimulatorCLIOptions.parse(arguments), arguments.joined(separator: " "))
        }
        for request in [SimulatorCommandRequest(action: .list, device: "Pixel"),
                        SimulatorCommandRequest(action: .boot, device: "Pixel\nInjected"),
                        SimulatorCommandRequest(action: .stop), SimulatorCommandRequest(action: .boot, timeout: 601),
                        SimulatorCommandRequest(action: .boot, createdAt: Date().addingTimeInterval(100)),
                        SimulatorCommandRequest(action: .install, device: "Pixel", argument: "/tmp/file.txt")] {
            XCTAssertThrowsError(try request.validated())
        }
        for value in ["file:///etc/passwd", "content://private", "javascript:alert(1)", "data:text/plain,test", "android-simulator://command/test", "droiddock://command/test", "DROIDDOCK://command/test", "no-scheme", "https://a\nnext"] {
            XCTAssertFalse(SimulatorCommandRequest.isValidLaunchURL(value), value)
        }
        for value in ["exp://localhost:8081", "exps://example.com", "https://example.com/path", "myapp://screen?id=1"] {
            XCTAssertTrue(SimulatorCommandRequest.isValidLaunchURL(value), value)
        }
    }

    func testAppDiscoveryPrefersDroidDockAndRetainsExplicitEnvironmentAndBundleCompatibility() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        let environment = ["DROIDDOCK_APP": "/custom/DroidDock.app", "ANDROID_SIMULATOR_APP": "/legacy/Android Simulator.app"]
        func candidates(_ explicit: String? = nil, environment: [String: String] = [:], executable: URL? = nil) -> [String] {
            SimulatorCLIAppDiscovery.candidates(explicitPath: explicit, environment: environment,
                                                executableURL: executable, homeDirectory: home).map(\.path)
        }
        XCTAssertEqual(candidates("/explicit/Chosen.app", environment: environment), ["/explicit/Chosen.app"])
        XCTAssertEqual(candidates(environment: environment), ["/custom/DroidDock.app"])
        XCTAssertEqual(candidates(environment: ["ANDROID_SIMULATOR_APP": environment["ANDROID_SIMULATOR_APP"]!]), ["/legacy/Android Simulator.app"])
        XCTAssertEqual(candidates(), ["/Applications/DroidDock.app", "/Users/fixture/Applications/DroidDock.app",
                                     "/Applications/Android Simulator.app", "/Users/fixture/Applications/Android Simulator.app"])
        let bundled = URL(fileURLWithPath: "/custom/DroidDock.app/Contents/MacOS/android-simulator")
        XCTAssertEqual(candidates(executable: bundled).first, "/custom/DroidDock.app")
        XCTAssertEqual(SimulatorCommandStore.defaultDirectory.lastPathComponent, "Commands")
        XCTAssertEqual(SimulatorCommandStore.defaultDirectory.deletingLastPathComponent().lastPathComponent, "AndroidSimulator",
                       "Branding must not move the existing local command mailbox")
    }
}

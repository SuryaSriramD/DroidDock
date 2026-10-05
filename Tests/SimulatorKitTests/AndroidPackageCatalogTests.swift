import XCTest
@testable import SimulatorKit

final class AndroidPackageCatalogTests: XCTestCase {
    private let imageID = AndroidPackageCatalog.systemImageID
    private let licenseText = "\n Terms &amp; Conditions\n\n Keep this spacing.\n "
    private let digest = String(repeating: "a", count: 40)

    private func archive(url: String = "fixture.zip", host: String? = nil, architecture: String? = nil,
                         size: String = "100", checksum: String? = nil, algorithm: String = "sha1", bits: String? = nil) -> String {
        """
        <archive><complete><size>\(size)</size><checksum type="\(algorithm)">\(checksum ?? digest)</checksum><url>\(url)</url></complete>
        \(host.map { "<host-os>\($0)</host-os>" } ?? "")
        \(architecture.map { "<host-arch>\($0)</host-arch>" } ?? "")
        \(bits.map { "<host-bits>\($0)</host-bits>" } ?? "")</archive>
        """
    }

    private func package(_ id: String, major: Int = 1, minor: Int = 0, micro: Int = 0, channel: String = "channel-0",
                         preview: Int? = nil, license: String? = "sdk", archives: String? = nil,
                         dependencies: String = "", obsolete: Bool = false, codename: String? = nil,
                         typeDetails: String? = nil) -> String {
        let defaultArchive = id == "emulator" ? archive(host: "macosx", architecture: "aarch64") : id == "platform-tools" ? archive(host: "macosx") : archive()
        let parts = id.split(separator: ";")
        let details: String
        if let typeDetails { details = typeDetails }
        else if parts.count == 4, parts[0] == "system-images" {
            details = "<type-details><api-level>\(parts[1].dropFirst(8))</api-level><abi>\(parts[3])</abi><tag><id>\(parts[2])</id></tag>\(codename.map { "<codename>\($0)</codename>" } ?? "")</type-details>"
        } else { details = "<type-details/>" }
        return """
        <remotePackage path="\(id)"\(obsolete ? " obsolete=\"true\"" : "")><revision><major>\(major)</major><minor>\(minor)</minor><micro>\(micro)</micro>\(preview.map { "<preview>\($0)</preview>" } ?? "")</revision>
        \(details)
        <display-name>\(id) display</display-name>\(license.map { "<uses-license ref=\"\($0)\"/>" } ?? "")<channelRef ref="\(channel)"/>
        <archives>\(archives ?? defaultArchive)</archives>\(dependencies)</remotePackage>
        """
    }

    private func repository(_ packages: String? = nil, licenses: String? = nil) -> Data {
        Data("""
        <?xml version="1.0"?><sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03">
        \(licenses ?? "<license id=\"sdk\" type=\"text\">\(licenseText)</license>")
        \(packages ?? (package("emulator") + package("platform-tools")))</sdk:sdk-repository>
        """.utf8)
    }

    private func images(_ packages: String? = nil, licenses: String? = nil) -> Data {
        Data("""
        <?xml version="1.0"?><sys:sdk-sys-img xmlns:sys="http://schemas.android.com/sdk/android/repo/sys-img2/03">
        \(licenses ?? "<license id=\"sdk\" type=\"text\">\(licenseText)</license>")
        \(packages ?? package(imageID))</sys:sdk-sys-img>
        """.utf8)
    }

    func testPlanContainsExactlyRequiredPackagesOfficialURLsAndRawLicense() throws {
        let plan = try AndroidPackageCatalog.parse(repository: repository(), systemImages: images())
        XCTAssertEqual(plan.packages.map(\.id), ["emulator", "platform-tools", imageID])
        XCTAssertEqual(plan.packages.map(\.archiveRoot), ["emulator", "platform-tools", "arm64-v8a"])
        XCTAssertEqual(plan.packages.map(\.relativeInstallPath), ["emulator", "platform-tools", "system-images/android-36/google_apis/arm64-v8a"])
        XCTAssertEqual(plan.packages[0].archiveURL.absoluteString, "https://dl.google.com/android/repository/fixture.zip")
        XCTAssertEqual(plan.packages[2].archiveURL.absoluteString, "https://dl.google.com/android/repository/sys-img/google_apis/fixture.zip")
        XCTAssertEqual(plan.downloadBytes, 300)
        XCTAssertEqual(plan.runtime, .legacy)
        XCTAssertEqual(plan.licenses, [AndroidSDKLicense(id: "sdk", text: "\n Terms & Conditions\n\n Keep this spacing.\n ")])
    }

    func testNewestStableRevisionWinsNumericallyAndPreviewsAreExcluded() throws {
        let variants = package("emulator", major: 9, minor: 99, archives: archive(url: "old.zip", host: "macosx", architecture: "aarch64"))
            + package("emulator", major: 10, minor: 2, micro: 1, archives: archive(url: "selected.zip", host: "macosx", architecture: "aarch64"))
            + package("emulator", major: 10, minor: 2, micro: 0)
            + package("emulator", major: 99, channel: "channel-1")
            + package("emulator", major: 100, preview: 1)
            + package("emulator", major: 101, obsolete: true)
            + package("platform-tools")
        let plan = try AndroidPackageCatalog.parse(repository: repository(variants), systemImages: images())
        XCTAssertEqual(plan.packages[0].archiveURL.lastPathComponent, "selected.zip")
        XCTAssertEqual(plan.packages[0].revision, "10.2.1")
    }

    func testChoosesAppleSiliconArchiveOverIntelAndOtherOperatingSystems() throws {
        let archives = archive(url: "intel.zip", host: "macosx", architecture: "x64")
            + archive(url: "linux.zip", host: "linux", architecture: "aarch64")
            + archive(url: "arm.zip", host: "macosx", architecture: "aarch64")
        let plan = try AndroidPackageCatalog.parse(repository: repository(package("emulator", archives: archives) + package("platform-tools")), systemImages: images())
        XCTAssertEqual(plan.packages[0].archiveURL.lastPathComponent, "arm.zip")
    }

    func testUnspecifiedArchitectureIsAllowedOnlyForSharedPlatformTools() throws {
        XCTAssertNoThrow(try AndroidPackageCatalog.parse(repository: repository(), systemImages: images()))
        for archive in [archive(host: "macosx"), archive(host: "macosx", architecture: "x64"), archive(host: "linux", architecture: "aarch64"), archive(host: "macosx", architecture: "aarch64", bits: "32")] {
            XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: repository(package("emulator", archives: archive) + package("platform-tools")), systemImages: images()))
        }
        XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: repository(package("emulator") + package("platform-tools", archives: archive(host: "macosx", architecture: "x64"))), systemImages: images()))
    }

    func testSystemImageMustBeHostNeutralAndExactRequestedABI() {
        XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: repository(), systemImages: images(package(imageID, archives: archive(host: "linux")))))
        XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: repository(), systemImages: images(package("system-images;android-36;google_apis;x86_64"))))
    }

    func testIncludesAdditionalSystemImageLicenseWithoutChangingText() throws {
        let license = "<license id=\"arm-license\" type=\"text\"><![CDATA[\nExtra & exact terms.\n]]></license>"
        let plan = try AndroidPackageCatalog.parse(repository: repository(), systemImages: images(package(imageID, license: "arm-license"), licenses: license))
        XCTAssertEqual(plan.licenses.map(\.id), ["sdk", "arm-license"])
        XCTAssertEqual(plan.licenses[1].text, "\nExtra & exact terms.\n")
    }

    func testMissingOrConflictingLicenseFailsClosed() {
        for invalid in [images(licenses: ""), images(licenses: "<license id=\"sdk\"> </license>"), images(package(imageID, license: nil)), images(package(imageID, license: "missing")), images(licenses: "<license id=\"sdk\">Different terms</license>"), images(licenses: "<license id=\"sdk\">One</license><license id=\"sdk\">Two</license>")] {
            XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: repository(), systemImages: invalid))
        }
    }

    func testDoesNotFallBackToOldRevisionWhenNewestLicenseIsMissing() {
        let packages = package("emulator", major: 1) + package("emulator", major: 2, license: "missing") + package("platform-tools")
        XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: repository(packages), systemImages: images()))
    }

    func testRejectsUntrustedAndAmbiguousArchiveURLs() {
        let invalidURLs = ["https://evil.example/fixture.zip", "http://dl.google.com/android/repository/fixture.zip", "//evil.example/fixture.zip", "../fixture.zip", "sub/../fixture.zip", "%2e%2e/fixture.zip", "https://dl.google.com/elsewhere/fixture.zip", "https://user@dl.google.com/android/repository/fixture.zip", "https://dl.google.com:443/android/repository/fixture.zip", "fixture.zip?token=one", "fixture.zip#fragment", "sub\\fixture.zip", "/android/repository/fixture.zip", "fixture.tar.gz"]
        for url in invalidURLs {
            XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: repository(package("emulator", archives: archive(url: url, host: "macosx", architecture: "aarch64")) + package("platform-tools")), systemImages: images()), url)
        }
    }

    func testAcceptsExplicitOfficialHTTPSURLAndSHA256Checksum() throws {
        let archive = archive(url: "https://dl.google.com/android/repository/verified.zip", host: "macosx", architecture: "arm64", checksum: String(repeating: "B", count: 64), algorithm: "sha256")
        let plan = try AndroidPackageCatalog.parse(repository: repository(package("emulator", archives: archive) + package("platform-tools")), systemImages: images())
        XCTAssertEqual(plan.packages[0].checksum, String(repeating: "b", count: 64))
        XCTAssertEqual(plan.packages[0].checksumType, "sha256")
    }

    func testRejectsMalformedSizesAndChecksums() {
        let bad = [archive(size: "0"), archive(size: "-1"), archive(size: "999999999999999999999"), archive(checksum: "short"), archive(checksum: String(repeating: "g", count: 40)), archive(algorithm: "md5")]
        for archive in bad {
            XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: repository(), systemImages: images(package(imageID, archives: archive))))
        }
    }

    func testRejectsMalformedXMLWrongNamespaceAndEntityDeclarations() {
        let invalid = [Data(), Data("<broken".utf8), Data("<sdk-repository/>".utf8), Data("<!DOCTYPE sdk-repository [<!ENTITY test 'boom'>]><sdk-repository>&test;</sdk-repository>".utf8)]
        for data in invalid { XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: data, systemImages: images())) }
    }

    func testRejectsUnsatisfiedPackageDependencies() throws {
        let satisfied = "<dependencies><dependency path=\"emulator\"><min-revision><major>1</major></min-revision></dependency></dependencies>"
        XCTAssertNoThrow(try AndroidPackageCatalog.parse(repository: repository(), systemImages: images(package(imageID, dependencies: satisfied))))
        for dependency in ["<dependencies><dependency path=\"emulator\"><min-revision><major>2</major></min-revision></dependency></dependencies>", "<dependencies><dependency path=\"unknown\"/></dependencies>"] {
            XCTAssertThrowsError(try AndroidPackageCatalog.parse(repository: repository(), systemImages: images(package(imageID, dependencies: dependency))))
        }
    }

    func testRuntimeIdentityDerivesSafeDistinctPathsAndPhoneNames() throws {
        let latest = try XCTUnwrap(AndroidRuntimeVersion(packageID: "system-images;android-37.0;google_apis;arm64-v8a"))
        XCTAssertEqual(latest.apiLevel, "37.0")
        XCTAssertEqual(latest.title, "Android 17 · API 37.0")
        XCTAssertEqual(latest.imagePath, "system-images/android-37.0/google_apis/arm64-v8a")
        XCTAssertEqual(latest.deviceName, "DroidDock_Phone_API_37_0")
        XCTAssertEqual(AndroidRuntimeVersion.legacy.deviceName, "DroidDock_Phone_API_36")
        let future = try XCTUnwrap(AndroidRuntimeVersion(packageID: "system-images;android-38.2;google_apis;arm64-v8a"))
        XCTAssertEqual(future.title, "Android API 38.2")
        let minor = try XCTUnwrap(AndroidRuntimeVersion(packageID: "system-images;android-36.1;google_apis;arm64-v8a"))
        XCTAssertEqual(minor.title, "Android 16 · API 36.1")
        XCTAssertNotEqual(minor.deviceName, AndroidRuntimeVersion.legacy.deviceName)
    }

    func testRuntimeIdentityRejectsPreviewAlternativeABIAndUnsafeComponents() {
        let invalid = [
            "system-images;android-29;google_apis;arm64-v8a",
            "system-images;android-37.2-beta3;google_apis;arm64-v8a",
            "system-images;android-CANARY;google_apis;arm64-v8a",
            "system-images;android-37;google_apis_ps16k;arm64-v8a",
            "system-images;android-37;google_apis;x86_64",
            "system-images;android-37;google_apis;arm64-v8a;extra",
            "system-images;android-../37;google_apis;arm64-v8a",
            "system-images;android-037;google_apis;arm64-v8a",
            "system-images;android-37.01;google_apis;arm64-v8a",
            "system-images;android-37.0\n;google_apis;arm64-v8a",
            "system-images;android-37.0.1;google_apis;arm64-v8a"
        ]
        for id in invalid { XCTAssertNil(AndroidRuntimeVersion(packageID: id), id) }
    }

    func testAvailablePlansSortNumericAPIAndLatestWrapperChoosesNewest() throws {
        let apiLevels = ["36", "36.2", "37.0", "30", "36.10"]
        let manifest = images(apiLevels.map { package("system-images;android-\($0);google_apis;arm64-v8a") }.joined())
        let available = try AndroidPackageCatalog.parseAvailable(repository: repository(), systemImages: manifest)
        XCTAssertEqual(available.map { $0.runtime.apiLevel }, ["37.0", "36.10", "36.2", "36", "30"])
        XCTAssertEqual(try AndroidPackageCatalog.parse(repository: repository(), systemImages: manifest), available[0])
        XCTAssertEqual(Set(available.map { $0.runtime.deviceName }).count, apiLevels.count)
        for plan in available {
            XCTAssertEqual(plan.packages[2].id, plan.runtime.id)
            XCTAssertEqual(plan.packages[2].relativeInstallPath, plan.runtime.imagePath)
        }
    }

    func testDuplicateImageVersionsUseHighestStableRevisionWithoutDuplicatePlans() throws {
        let newerID = "system-images;android-37.0;google_apis;arm64-v8a"
        let manifest = images(package(newerID, major: 2, archives: archive(url: "revision2.zip"))
            + package(newerID, major: 10, archives: archive(url: "revision10.zip"))
            + package(newerID, major: 99, preview: 1)
            + package(imageID))
        let plans = try AndroidPackageCatalog.parseAvailable(repository: repository(), systemImages: manifest)
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans[0].packages[2].archiveURL.lastPathComponent, "revision10.zip")
        XCTAssertEqual(plans[0].packages[2].revision, "10.0.0")
    }

    func testChannelZeroCodenamesAndMalformedUnrelatedPreviewsAreIgnored() throws {
        let finalID = "system-images;android-37.0;google_apis;arm64-v8a"
        let brokenArchive = archive(url: "https://evil.example/not-an-image.zip", checksum: "broken")
        let previewIDs = [
            "system-images;android-canary-20260909;google_apis_ps16k;arm64-v8a",
            "system-images;android-37.2-beta3;google_apis_ps16k;arm64-v8a",
            "system-images;android-39;google_apis;arm64-v8a"
        ]
        let previews = previewIDs.map { package($0, major: -1, license: "missing", archives: brokenArchive, codename: "DEV") }.joined()
        let manifest = images(package(finalID) + package(imageID) + previews
            + package("system-images;android-40;google_apis;arm64-v8a", channel: "channel-1")
            + package("system-images;android-41;google_apis;arm64-v8a", preview: 1)
            + package("system-images;android-42;google_apis;arm64-v8a", obsolete: true))
        let plans = try AndroidPackageCatalog.parseAvailable(repository: repository(), systemImages: manifest)
        XCTAssertEqual(plans.map { $0.runtime.apiLevel }, ["37.0", "36"])
    }

    func testOnlyPreviewImagesCannotProduceAnInstallationPlan() {
        let manifest = images(package("system-images;android-37;google_apis;arm64-v8a", codename: "CinnamonBun"))
        XCTAssertThrowsError(try AndroidPackageCatalog.parseAvailable(repository: repository(), systemImages: manifest))
    }

    func testStableImageMetadataMustMatchPackageIdentity() {
        let badDetails = [
            "<type-details><api-level>37</api-level><abi>arm64-v8a</abi><tag><id>google_apis</id></tag></type-details>",
            "<type-details><api-level>36</api-level><abi>x86_64</abi><tag><id>google_apis</id></tag></type-details>",
            "<type-details><api-level>36</api-level><abi>arm64-v8a</abi><tag><id>google_apis_ps16k</id></tag></type-details>",
            "<type-details/>"
        ]
        for details in badDetails {
            XCTAssertThrowsError(try AndroidPackageCatalog.parseAvailable(repository: repository(), systemImages: images(package(imageID, typeDetails: details))))
        }
    }

    func testEveryPlanPreservesItsOwnRequiredLicenses() throws {
        let newerID = "system-images;android-37.0;google_apis;arm64-v8a"
        let licenses = "<license id=\"sdk\">\(licenseText)</license><license id=\"new-license\">New image terms\n</license>"
        let manifest = images(package(newerID, license: "new-license") + package(imageID), licenses: licenses)
        let plans = try AndroidPackageCatalog.parseAvailable(repository: repository(), systemImages: manifest)
        XCTAssertEqual(plans[0].licenses.map(\.id), ["sdk", "new-license"])
        XCTAssertEqual(plans[1].licenses.map(\.id), ["sdk"])
        XCTAssertEqual(plans[0].licenses[1].text, "New image terms\n")
    }

    func testPackagesExposeActualDependencyMinimumRatherThanLatestToolRevision() throws {
        let dependency = "<dependencies><dependency path=\"emulator\"><min-revision><major>35</major><minor>4</minor><micro>9</micro></min-revision></dependency><dependency path=\"platform-tools\"/></dependencies>"
        let tools = repository(package("emulator", major: 37, minor: 1, micro: 11) + package("platform-tools", major: 37))
        let plan = try AndroidPackageCatalog.parse(repository: tools, systemImages: images(package(imageID, dependencies: dependency)))
        XCTAssertEqual(plan.packages[0].revision, "37.1.11")
        XCTAssertEqual(plan.packages[2].minimumDependencies, ["emulator": "35.4.9", "platform-tools": "0"])
    }
}

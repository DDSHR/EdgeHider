import XCTest
@testable import EdgeHider

final class ConfigTests: XCTestCase {
    func testLegacyGlobalSettingsGetNewDefaults() throws {
        let data = Data(#"{"isMasterEnabled":false,"hotZoneWidth":8,"peekStripWidth":5,"launchAtLogin":false}"#.utf8)
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
        XCTAssertFalse(settings.isMasterEnabled)
        XCTAssertEqual(settings.hotZoneWidth, 8)
        XCTAssertEqual(settings.autoHideDelay, GlobalSettings.default.autoHideDelay)
    }

    func testInvalidSettingsAreRejected() {
        for json in [#"{"hotZoneWidth":-2}"#, #"{"peekStripWidth":400}"#, #"{"autoHideDelay":-1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8)))
        }
    }

    func testMinimalAppConfigurationKeepsIdentity() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"bundleIdentifier":"com.example.app"}"#.utf8))
        XCTAssertEqual(config.bundleIdentifier, "com.example.app")
        XCTAssertEqual(config.hiddenSide, .automatic)
        XCTAssertFalse(config.isEnabled)
    }

    func testInvalidAppThresholdIsRejected() {
        let data = Data(#"{"bundleIdentifier":"com.example.app","edgeThreshold":-1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppConfig.self, from: data))
    }

    func testUnsupportedVersionAndMismatchedIdentityAreRejected() {
        var config = AppConfig.default
        config.bundleIdentifier = "com.example.app"
        var file = ConfigFile(version: 999, exportedAt: Date(), globalSettings: .default, appConfigs: [:])
        XCTAssertThrowsError(try file.validate())
        file.version = ConfigFile.currentVersion
        file.appConfigs = ["com.other.app": config]
        XCTAssertThrowsError(try file.validate())
    }

    func testExportImportRoundTrip() throws {
        var config = AppConfig.default
        config.bundleIdentifier = "com.example.app"
        config.isEnabled = true
        config.hiddenSide = .bottom
        let original = ConfigFile(version: ConfigFile.currentVersion, exportedAt: Date(), globalSettings: .default,
                                  appConfigs: [config.bundleIdentifier: config])
        let data = try JSONEncoder.prettyEncoded.encode(original)
        let decoded = try JSONDecoder.imported.decode(ConfigFile.self, from: data)
        try decoded.validate()
        XCTAssertEqual(decoded.appConfigs, original.appConfigs)
        XCTAssertEqual(decoded.globalSettings.autoHideDelay, original.globalSettings.autoHideDelay)
    }
}

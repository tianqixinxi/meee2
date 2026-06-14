import XCTest
@testable import meee2Kit

final class WebBoardThemeProfileTests: XCTestCase {
    func testDefaultProfileIsClaudeV1() {
        let profile = WebBoardThemeProfile.defaultProfile()

        XCTAssertEqual(profile.schemaVersion, 1)
        XCTAssertEqual(profile.presetId, "claude")
        XCTAssertEqual(profile.light.accentColor, "#B95F43")
        XCTAssertEqual(profile.light.sidebarColor, "#FBF8F1")
        XCTAssertEqual(profile.dark.backgroundColor, "#262624")
    }

    func testParseAcceptsSupportedProfileAndClampsContrast() {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "presetId": "custom",
            "light": [
                "accentColor": "#339cff",
                "backgroundColor": "#ffffff",
                "sidebarColor": "#f3f6fa",
                "foregroundColor": "#1a1c1f",
                "contrast": 145,
            ],
            "dark": [
                "accentColor": "#4da6ff",
                "backgroundColor": "#101214",
                "sidebarColor": "#171b20",
                "foregroundColor": "#f4f7fb",
                "contrast": -10,
            ],
        ]

        let profile = WebBoardThemeProfile.parse(object)

        XCTAssertEqual(profile?.presetId, "custom")
        XCTAssertEqual(profile?.light.accentColor, "#339CFF")
        XCTAssertEqual(profile?.light.sidebarColor, "#F3F6FA")
        XCTAssertEqual(profile?.light.contrast, 100)
        XCTAssertEqual(profile?.dark.contrast, 0)
    }

    func testParseRejectsUnsupportedProfile() {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "presetId": "shared",
            "light": [:],
            "dark": [:],
        ]

        XCTAssertNil(WebBoardThemeProfile.parse(object))

        object["presetId"] = "custom"
        object["light"] = [
            "accentColor": "blue",
            "backgroundColor": "#ffffff",
            "foregroundColor": "#1a1c1f",
            "contrast": 45,
        ]
        object["dark"] = object["light"]

        XCTAssertNil(WebBoardThemeProfile.parse(object))
    }

    func testParseAcceptsLegacyV1ProfileWithoutSidebarColor() {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "presetId": "custom",
            "light": [
                "accentColor": "#339cff",
                "backgroundColor": "#ffffff",
                "foregroundColor": "#1a1c1f",
                "contrast": 45,
            ],
            "dark": [
                "accentColor": "#4da6ff",
                "backgroundColor": "#101214",
                "foregroundColor": "#f4f7fb",
                "contrast": 62,
            ],
        ]

        let profile = WebBoardThemeProfile.parse(object)

        XCTAssertEqual(profile?.light.sidebarColor, "#FFFFFF")
        XCTAssertEqual(profile?.dark.sidebarColor, "#101214")
    }

    func testStoredProfileFallsBackWhenStoredDataIsUnreadable() {
        let suiteName = "WebBoardThemeProfileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data([0x7B, 0x7D]), forKey: WebBoardThemeProfile.defaultsKey)

        let profile = WebBoardThemeProfile.storedProfile(defaults: defaults)
        XCTAssertEqual(profile, WebBoardThemeProfile.defaultProfile())
    }
}

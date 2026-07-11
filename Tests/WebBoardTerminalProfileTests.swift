import XCTest
@testable import meee2Kit

final class WebBoardTerminalProfileTests: XCTestCase {
    func testDefaultProfileMatchesExistingTerminalAppearance() {
        let profile = WebBoardTerminalProfile.defaultProfile()

        XCTAssertEqual(profile.fontSize, 14)
        XCTAssertEqual(profile.lineHeightPercent, 100)
        XCTAssertEqual(profile.cursorStyle, "block")
        XCTAssertTrue(profile.cursorBlink)
        XCTAssertEqual(profile.paddingX, 10)
        XCTAssertEqual(profile.paddingY, 8)
        XCTAssertTrue(profile.useThemeColors)
        XCTAssertFalse(profile.fontThicken)
    }

    func testParseSanitizesAndClampsValues() {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "fontFamily": "  JetBrains Mono  ",
            "fontSize": 80,
            "lineHeightPercent": 20,
            "fontThicken": false,
            "cursorStyle": "bar",
            "cursorBlink": false,
            "paddingX": 99,
            "paddingY": -5,
            "useThemeColors": false,
            "backgroundColor": "#101214",
            "foregroundColor": "#f4f7fb",
            "accentColor": "#4da6ff",
        ]

        let profile = WebBoardTerminalProfile.parse(object)

        XCTAssertEqual(profile?.fontFamily, "JetBrains Mono")
        XCTAssertEqual(profile?.fontSize, 32)
        XCTAssertEqual(profile?.lineHeightPercent, 80)
        XCTAssertEqual(profile?.paddingX, 48)
        XCTAssertEqual(profile?.paddingY, 0)
        XCTAssertEqual(profile?.foregroundColor, "#F4F7FB")
        XCTAssertEqual(profile?.accentColor, "#4DA6FF")
    }

    func testParseRejectsInvalidCursorAndColor() {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "fontFamily": "",
            "fontSize": 14,
            "lineHeightPercent": 100,
            "fontThicken": true,
            "cursorStyle": "beam",
            "cursorBlink": true,
            "paddingX": 10,
            "paddingY": 8,
            "useThemeColors": false,
            "backgroundColor": "#101214",
            "foregroundColor": "#F4F7FB",
            "accentColor": "#4DA6FF",
        ]

        XCTAssertNil(WebBoardTerminalProfile.parse(object))
        object["cursorStyle"] = "underline"
        object["accentColor"] = "blue"
        XCTAssertNil(WebBoardTerminalProfile.parse(object))
    }

    func testStoredProfileFallsBackWhenStoredDataIsUnreadable() {
        let suiteName = "WebBoardTerminalProfileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data([0x7B, 0x7D]), forKey: WebBoardTerminalProfile.defaultsKey)

        XCTAssertEqual(
            WebBoardTerminalProfile.storedProfile(defaults: defaults),
            WebBoardTerminalProfile.defaultProfile()
        )
    }
}

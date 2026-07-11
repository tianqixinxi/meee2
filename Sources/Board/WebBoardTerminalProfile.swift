import Foundation

public struct WebBoardTerminalProfileDTO: Codable, Equatable {
    public let schemaVersion: Int
    public let fontFamily: String
    public let fontSize: Double
    public let lineHeightPercent: Int
    public let fontThicken: Bool
    public let cursorStyle: String
    public let cursorBlink: Bool
    public let paddingX: Int
    public let paddingY: Int
    public let useThemeColors: Bool
    public let backgroundColor: String
    public let foregroundColor: String
    public let accentColor: String

    public init(
        schemaVersion: Int,
        fontFamily: String,
        fontSize: Double,
        lineHeightPercent: Int,
        fontThicken: Bool,
        cursorStyle: String,
        cursorBlink: Bool,
        paddingX: Int,
        paddingY: Int,
        useThemeColors: Bool,
        backgroundColor: String,
        foregroundColor: String,
        accentColor: String
    ) {
        self.schemaVersion = schemaVersion
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeightPercent = lineHeightPercent
        self.fontThicken = fontThicken
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.useThemeColors = useThemeColors
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.accentColor = accentColor
    }
}

public enum WebBoardTerminalProfile {
    public static let defaultsKey = "meee2.terminalProfile"
    public static let schemaVersion = 1

    public static func defaultProfile() -> WebBoardTerminalProfileDTO {
        WebBoardTerminalProfileDTO(
            schemaVersion: schemaVersion,
            fontFamily: "",
            fontSize: 14,
            lineHeightPercent: 100,
            fontThicken: false,
            cursorStyle: "block",
            cursorBlink: true,
            paddingX: 10,
            paddingY: 8,
            useThemeColors: true,
            backgroundColor: "#101214",
            foregroundColor: "#F4F7FB",
            accentColor: "#4DA6FF"
        )
    }

    public static func storedProfile(defaults: UserDefaults = .standard) -> WebBoardTerminalProfileDTO {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(WebBoardTerminalProfileDTO.self, from: data) else {
            return defaultProfile()
        }
        return sanitized(decoded) ?? defaultProfile()
    }

    public static func store(_ profile: WebBoardTerminalProfileDTO, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    public static func parse(_ value: Any?) -> WebBoardTerminalProfileDTO? {
        guard let object = value,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? JSONDecoder().decode(WebBoardTerminalProfileDTO.self, from: data) else {
            return nil
        }
        return sanitized(decoded)
    }

    public static func sanitized(_ profile: WebBoardTerminalProfileDTO) -> WebBoardTerminalProfileDTO? {
        let fontFamily = profile.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.schemaVersion == schemaVersion,
              profile.fontSize.isFinite,
              fontFamily.count <= 128,
              !fontFamily.contains("\n"),
              ["block", "bar", "underline"].contains(profile.cursorStyle),
              isHexColor(profile.backgroundColor),
              isHexColor(profile.foregroundColor),
              isHexColor(profile.accentColor) else {
            return nil
        }
        return WebBoardTerminalProfileDTO(
            schemaVersion: schemaVersion,
            fontFamily: fontFamily,
            fontSize: max(9, min(32, profile.fontSize)),
            lineHeightPercent: max(80, min(180, profile.lineHeightPercent)),
            fontThicken: profile.fontThicken,
            cursorStyle: profile.cursorStyle,
            cursorBlink: profile.cursorBlink,
            paddingX: max(0, min(48, profile.paddingX)),
            paddingY: max(0, min(48, profile.paddingY)),
            useThemeColors: profile.useThemeColors,
            backgroundColor: profile.backgroundColor.uppercased(),
            foregroundColor: profile.foregroundColor.uppercased(),
            accentColor: profile.accentColor.uppercased()
        )
    }

    private static func isHexColor(_ value: String) -> Bool {
        value.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil
    }
}

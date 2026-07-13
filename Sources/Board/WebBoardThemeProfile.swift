import Foundation

struct WebBoardThemeProfileDTO: Codable, Equatable {
    let schemaVersion: Int
    let presetId: String
    let light: WebBoardThemeBranchDTO
    let dark: WebBoardThemeBranchDTO
}

struct WebBoardThemeBranchDTO: Codable, Equatable {
    let accentColor: String
    let backgroundColor: String
    let sidebarColor: String
    let foregroundColor: String
    let contrast: Double

    init(
        accentColor: String,
        backgroundColor: String,
        sidebarColor: String,
        foregroundColor: String,
        contrast: Double
    ) {
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        self.sidebarColor = sidebarColor
        self.foregroundColor = foregroundColor
        self.contrast = contrast
    }

    enum CodingKeys: String, CodingKey {
        case accentColor
        case backgroundColor
        case sidebarColor
        case foregroundColor
        case contrast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let backgroundColor = try container.decode(String.self, forKey: .backgroundColor)
        self.accentColor = try container.decode(String.self, forKey: .accentColor)
        self.backgroundColor = backgroundColor
        self.sidebarColor = try container.decodeIfPresent(String.self, forKey: .sidebarColor) ?? backgroundColor
        self.foregroundColor = try container.decode(String.self, forKey: .foregroundColor)
        self.contrast = try container.decode(Double.self, forKey: .contrast)
    }
}

enum WebBoardThemeProfile {
    static let defaultsKey = "meee2.themeProfile"
    static let codexDefaultMigrationKey = "meee2.themeProfile.defaultCodexMigration.v2"
    static let schemaVersion = 1
    static let supportedPresetIds = Set(["claude", "codex", "custom"])

    static let claude = WebBoardThemeProfileDTO(
        schemaVersion: schemaVersion,
        presetId: "claude",
        light: WebBoardThemeBranchDTO(
            accentColor: "#B95F43",
            backgroundColor: "#F4F1EA",
            sidebarColor: "#FBF8F1",
            foregroundColor: "#25211D",
            contrast: 55
        ),
        dark: WebBoardThemeBranchDTO(
            accentColor: "#CC785C",
            backgroundColor: "#262624",
            sidebarColor: "#2C2B29",
            foregroundColor: "#F5F4EF",
            contrast: 58
        )
    )

    static let codex = WebBoardThemeProfileDTO(
        schemaVersion: schemaVersion,
        presetId: "codex",
        light: WebBoardThemeBranchDTO(
            accentColor: "#339CFF",
            backgroundColor: "#FFFFFF",
            sidebarColor: "#FFFFFF",
            foregroundColor: "#1A1C1F",
            contrast: 45
        ),
        dark: WebBoardThemeBranchDTO(
            accentColor: "#4DA6FF",
            backgroundColor: "#101214",
            sidebarColor: "#171B20",
            foregroundColor: "#F4F7FB",
            contrast: 62
        )
    )

    static func defaultProfile() -> WebBoardThemeProfileDTO {
        codex
    }

    static func storedProfile(defaults: UserDefaults = .standard) -> WebBoardThemeProfileDTO {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(WebBoardThemeProfileDTO.self, from: data),
              let profile = sanitized(decoded) else {
            defaults.set(true, forKey: codexDefaultMigrationKey)
            return defaultProfile()
        }
        if !defaults.bool(forKey: codexDefaultMigrationKey), profile.presetId == "claude" {
            store(codex, defaults: defaults)
            return codex
        }
        defaults.set(true, forKey: codexDefaultMigrationKey)
        return profile
    }

    static func store(_ profile: WebBoardThemeProfileDTO, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: defaultsKey)
        defaults.set(true, forKey: codexDefaultMigrationKey)
    }

    static func parse(_ value: Any?) -> WebBoardThemeProfileDTO? {
        guard let object = value else { return nil }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? JSONDecoder().decode(WebBoardThemeProfileDTO.self, from: data) else {
            return nil
        }
        return sanitized(decoded)
    }

    static func sanitized(_ profile: WebBoardThemeProfileDTO) -> WebBoardThemeProfileDTO? {
        guard profile.schemaVersion == schemaVersion,
              supportedPresetIds.contains(profile.presetId),
              let light = sanitized(profile.light),
              let dark = sanitized(profile.dark) else {
            return nil
        }
        return WebBoardThemeProfileDTO(
            schemaVersion: schemaVersion,
            presetId: profile.presetId,
            light: light,
            dark: dark
        )
    }

    private static func sanitized(_ branch: WebBoardThemeBranchDTO) -> WebBoardThemeBranchDTO? {
        guard isHexColor(branch.accentColor),
              isHexColor(branch.backgroundColor),
              isHexColor(branch.sidebarColor),
              isHexColor(branch.foregroundColor),
              branch.contrast.isFinite else {
            return nil
        }
        return WebBoardThemeBranchDTO(
            accentColor: branch.accentColor.uppercased(),
            backgroundColor: branch.backgroundColor.uppercased(),
            sidebarColor: branch.sidebarColor.uppercased(),
            foregroundColor: branch.foregroundColor.uppercased(),
            contrast: max(0, min(100, branch.contrast))
        )
    }

    private static func isHexColor(_ value: String) -> Bool {
        let pattern = #"^#[0-9A-Fa-f]{6}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

}

import AppKit
import GhosttyTerminal
import meee2Kit

enum NativeTerminalTheme {
    private struct StoredProfile: Decodable {
        let schemaVersion: Int
        let light: Branch
        let dark: Branch
    }

    private struct Branch: Decodable {
        let accentColor: String
        let backgroundColor: String
        let foregroundColor: String
    }

    private static let defaultsKey = "meee2.themeProfile"

    static func terminalTheme() -> TerminalTheme {
        let profile = storedProfile()
        return TerminalTheme(
            light: configuration(for: profile.light, fallbackPalette: lightPalette),
            dark: configuration(for: profile.dark, fallbackPalette: darkPalette)
        )
    }

    static func backgroundColor(theme: String) -> NSColor {
        let terminalProfile = WebBoardTerminalProfile.storedProfile()
        if !terminalProfile.useThemeColors {
            return nsColor(hex: terminalProfile.backgroundColor)
                ?? NSColor(calibratedWhite: 0.07, alpha: 1)
        }
        let branch = theme == "light" ? storedProfile().light : storedProfile().dark
        return nsColor(hex: branch.backgroundColor)
            ?? (theme == "light" ? .white : NSColor(calibratedWhite: 0.07, alpha: 1))
    }

    private static func configuration(for branch: Branch, fallbackPalette: [String]) -> TerminalConfiguration {
        let terminalProfile = WebBoardTerminalProfile.storedProfile()
        let background = sanitizedHex(terminalProfile.useThemeColors ? branch.backgroundColor : terminalProfile.backgroundColor) ?? "#101214"
        let foreground = sanitizedHex(terminalProfile.useThemeColors ? branch.foregroundColor : terminalProfile.foregroundColor) ?? "#F4F7FB"
        let accent = sanitizedHex(terminalProfile.useThemeColors ? branch.accentColor : terminalProfile.accentColor) ?? "#4DA6FF"
        let darkMode = relativeLuminance(background) < relativeLuminance(foreground)
        let selection = mix(background, accent, ratio: darkMode ? 0.30 : 0.18)
        let brightAccent = mix(accent, foreground, ratio: 0.24)
        var palette = fallbackPalette
        palette[4] = accent
        palette[12] = brightAccent
        palette[7] = mix(background, foreground, ratio: darkMode ? 0.78 : 0.18)
        palette[15] = foreground

        return TerminalConfiguration { builder in
            builder.withBackground(ghosttyColor(background))
            builder.withForeground(ghosttyColor(foreground))
            builder.withBoldColor(ghosttyColor(foreground))
            if !terminalProfile.fontFamily.isEmpty {
                builder.withFontFamily(terminalProfile.fontFamily)
            }
            builder.withCursorStyle(cursorStyle(terminalProfile.cursorStyle))
            builder.withCursorStyleBlink(terminalProfile.cursorBlink)
            builder.withCursorColor(ghosttyColor(accent))
            builder.withCursorText(ghosttyColor(background))
            builder.withSelectionBackground(ghosttyColor(selection))
            builder.withSelectionForeground(ghosttyColor(foreground))
            builder.withMinimumContrast(1.05)
            builder.withFontSize(Float(terminalProfile.fontSize))
            builder.withFontThicken(terminalProfile.fontThicken)
            let lineHeightAdjustment = terminalProfile.lineHeightPercent - 100
            if lineHeightAdjustment != 0 {
                builder.withCustom("adjust-cell-height", "\(lineHeightAdjustment)%")
            }
            builder.withWindowPaddingX(terminalProfile.paddingX)
            builder.withWindowPaddingY(terminalProfile.paddingY)
            for (index, color) in palette.enumerated() {
                builder.withPalette(index, color: color)
            }
        }
    }

    private static func cursorStyle(_ value: String) -> TerminalCursorStyle {
        switch value {
        case "bar": return .bar
        case "underline": return .underline
        default: return .block
        }
    }

    private static func storedProfile() -> StoredProfile {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(StoredProfile.self, from: data),
           decoded.schemaVersion == 1,
           sanitizedHex(decoded.light.backgroundColor) != nil,
           sanitizedHex(decoded.dark.backgroundColor) != nil,
           sanitizedHex(decoded.light.foregroundColor) != nil,
           sanitizedHex(decoded.dark.foregroundColor) != nil,
           sanitizedHex(decoded.light.accentColor) != nil,
           sanitizedHex(decoded.dark.accentColor) != nil {
            return decoded
        }
        return defaultProfile
    }

    private static let defaultProfile = StoredProfile(
        schemaVersion: 1,
        light: Branch(accentColor: "#B95F43", backgroundColor: "#F4F1EA", foregroundColor: "#25211D"),
        dark: Branch(accentColor: "#CC785C", backgroundColor: "#262624", foregroundColor: "#F5F4EF")
    )

    private static let lightPalette = [
        "#1F2937", "#DC2626", "#16A34A", "#D97706",
        "#2563EB", "#9333EA", "#0891B2", "#E5E7EB",
        "#6B7280", "#EF4444", "#22C55E", "#F59E0B",
        "#3B82F6", "#A855F7", "#06B6D4", "#FFFFFF"
    ]

    private static let darkPalette = [
        "#0B0F14", "#FF6B6B", "#7DDC8F", "#FFD166",
        "#7AB7FF", "#D38CFF", "#5EEAD4", "#D8DEE9",
        "#6B7280", "#FF8A8A", "#9AF2AA", "#FFE08A",
        "#9DCCFF", "#E0AAFF", "#8CF7E7", "#FFFFFF"
    ]

    private static func sanitizedHex(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard candidate.count == 6, candidate.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#\(candidate.uppercased())"
    }

    private static func ghosttyColor(_ value: String) -> String {
        String((sanitizedHex(value) ?? "#000000").dropFirst())
    }

    private static func nsColor(hex: String) -> NSColor? {
        guard let sanitized = sanitizedHex(hex),
              let value = Int(String(sanitized.dropFirst()), radix: 16) else {
            return nil
        }
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    private static func mix(_ left: String, _ right: String, ratio: Double) -> String {
        let l = rgb(left)
        let r = rgb(right)
        let amount = max(0, min(1, ratio))
        return String(
            format: "#%02X%02X%02X",
            Int(round(Double(l.0) + (Double(r.0) - Double(l.0)) * amount)),
            Int(round(Double(l.1) + (Double(r.1) - Double(l.1)) * amount)),
            Int(round(Double(l.2) + (Double(r.2) - Double(l.2)) * amount))
        )
    }

    private static func rgb(_ hex: String) -> (Int, Int, Int) {
        let raw = String((sanitizedHex(hex) ?? "#000000").dropFirst())
        let value = Int(raw, radix: 16) ?? 0
        return ((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
    }

    private static func relativeLuminance(_ hex: String) -> Double {
        let (r, g, b) = rgb(hex)
        func channel(_ value: Int) -> Double {
            let scalar = Double(value) / 255
            return scalar <= 0.03928 ? scalar / 12.92 : pow((scalar + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}

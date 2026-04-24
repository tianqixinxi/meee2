import Foundation

// MARK: - Color Pair Indices

/// Color pair indices for ANSI colors
public enum ColorPair: Int16 {
    case header = 1
    case green = 2
    case yellow = 3
    case red = 4
    case cyan = 5
    case userMsg = 6
    case asstMsg = 7
    case dim = 8
    case tableBorder = 9
    case selectedBg = 10
    case tool = 11
}

// MARK: - Status Color Mapping

/// Map session status to color pair
public func statusColorPair(_ status: String) -> ColorPair {
    switch status {
    case "active", "running":
        return .green
    case "idle":
        return .yellow
    case "waiting", "waitingForUser", "permissionRequired":
        return .red
    case "dead", "failed":
        return .red
    case "completed":
        return .dim
    default:
        return .dim
    }
}

// MARK: - Color Initialization

/// Initialize curses colors (no-op for ANSI)
public func initCursesColors() {
    // ANSI colors don't need initialization
}

// MARK: - ANSI Color Strings

/// ANSI escape codes for colors
public struct ANSIColor {
    public static let reset = "\u{1B}[0m"
    public static let bold = "\u{1B}[1m"
    public static let dim = "\u{1B}[2m"
    public static let underline = "\u{1B}[4m"
    public static let reverse = "\u{1B}[7m"

    public static let green = "\u{1B}[32m"
    public static let yellow = "\u{1B}[33m"
    public static let red = "\u{1B}[31m"
    public static let cyan = "\u{1B}[36m"
    public static let magenta = "\u{1B}[35m"
    public static let white = "\u{1B}[37m"
    public static let blue = "\u{1B}[34m"

    public static let bgCyan = "\u{1B}[46m"
    public static let bgBlack = "\u{1B}[40m"

    public static func forStatus(_ status: String) -> String {
        switch status {
        case "active", "running": return green
        case "idle": return yellow
        case "waiting", "waitingForUser", "permissionRequired": return red
        case "dead", "failed": return red
        case "completed": return dim
        default: return white
        }
    }
}

// MARK: - Color Attribute Strings

/// Get ANSI string for color pair
public func colorString(_ pair: ColorPair) -> String {
    switch pair {
    case .header: return ANSIColor.bold
    case .green: return ANSIColor.green
    case .yellow: return ANSIColor.yellow
    case .red: return ANSIColor.red
    case .cyan: return ANSIColor.cyan
    case .userMsg: return ANSIColor.cyan + ANSIColor.bold
    case .asstMsg: return ANSIColor.yellow + ANSIColor.bold
    case .dim: return ANSIColor.dim
    case .tableBorder: return ANSIColor.dim
    case .selectedBg: return ANSIColor.bgCyan + ANSIColor.bold
    case .tool: return ANSIColor.magenta + ANSIColor.dim
    }
}

// MARK: - Chtype for curses compatibility

/// Chtype for curses compatibility (stores color + attribute info)
public func colorAttr(_ pair: ColorPair) -> Chtype {
    return Chtype(pair.rawValue)
}

/// Header attribute (bold + reverse)
public func headerAttr() -> Chtype {
    return A_BOLD | A_REVERSE
}

/// Green attribute
public func greenAttr() -> Chtype {
    return colorAttr(.green)
}

/// Yellow attribute
public func yellowAttr() -> Chtype {
    return colorAttr(.yellow)
}

/// Red attribute (for badges, errors)
public func redAttr() -> Chtype {
    return colorAttr(.red)
}

/// Cyan attribute
public func cyanAttr() -> Chtype {
    return colorAttr(.cyan)
}

/// Dim attribute (faded text)
public func dimAttr() -> Chtype {
    return A_DIM | colorAttr(.dim)
}

/// Selected row background attribute
public func selectedBgAttr() -> Chtype {
    return A_REVERSE | colorAttr(.selectedBg)
}

/// Table border attribute
public func tableBorderAttr() -> Chtype {
    return A_DIM
}

/// Tool call attribute
public func toolAttr() -> Chtype {
    return A_DIM | colorAttr(.tool)
}

/// User message prefix attribute
public func userMsgAttr() -> Chtype {
    return A_BOLD | colorAttr(.userMsg)
}

/// Assistant message prefix attribute
public func asstMsgAttr() -> Chtype {
    return A_BOLD | colorAttr(.asstMsg)
}

// MARK: - Apply Color to Text

/// Apply color and return the colored string
public func colored(_ text: String, _ pair: ColorPair, bold: Bool = false) -> String {
    let color = colorString(pair)
    let boldStr = bold ? ANSIColor.bold : ""
    return "\(boldStr)\(color)\(text)\(ANSIColor.reset)"
}

/// Apply attribute and return the string
public func withAttr(_ text: String, _ attr: Chtype) -> String {
    var codes = ""
    if attr & A_BOLD != 0 { codes += ANSIColor.bold }
    if attr & A_DIM != 0 { codes += ANSIColor.dim }
    if attr & A_REVERSE != 0 { codes += ANSIColor.reverse }
    return "\(codes)\(text)\(ANSIColor.reset)"
}

/// Type alias for backward compatibility
public typealias TUIColor = ANSIColor

import Foundation

// MARK: - ASCII Box Drawing Characters
//
/// ASCII box drawing characters (consistent width across all terminals)
public struct BoxChars {
    public static let horizontal = "-"
    public static let vertical = "|"
    public static let topLeft = "+"
    public static let topRight = "+"
    public static let bottomLeft = "+"
    public static let bottomRight = "+"
    public static let leftTee = "+"
    public static let rightTee = "+"
    public static let topTee = "+"
    public static let bottomTee = "+"
    public static let cross = "+"
}

// MARK: - Column Definition

/// Table column definition
public struct TableColumn {
    public let key: String
    public let header: String
    public let weight: Int  // Relative width weight

    public init(key: String, header: String, weight: Int) {
        self.key = key
        self.header = header
        self.weight = weight
    }
}

// MARK: - Column Registry

/// Default columns for session table (matches csm)
public let defaultColumns: [TableColumn] = [
    TableColumn(key: "badge", header: "", weight: 1),
    TableColumn(key: "id", header: "ID", weight: 4),
    TableColumn(key: "project", header: "PROJECT", weight: 6),
    TableColumn(key: "status", header: "STATUS", weight: 5),
    TableColumn(key: "cost", header: "COST", weight: 3),
    TableColumn(key: "last_msg", header: "LAST MSG", weight: 14),
    TableColumn(key: "updated", header: "UPDATED", weight: 4)
]

// MARK: - Column Width Calculation

/// Calculate column widths based on total available width
public func calcColumnWidths(totalWidth: Int, columns: [TableColumn] = defaultColumns) -> [Int] {
    let borders = columns.count + 1
    let available = max(columns.count, totalWidth - borders)
    let totalWeight = columns.reduce(0) { $0 + $1.weight }

    var widths: [Int] = []
    var used = 0

    for i in 0..<columns.count {
        if i == columns.count - 1 {
            // Last column takes remaining space
            widths.append(max(1, available - used))
        } else {
            let w = max(4, available * columns[i].weight / totalWeight)
            widths.append(w)
            used += w
        }
    }

    return widths
}

// MARK: - Horizontal Line Drawing

/// Draw a horizontal table border line using Unicode box characters
/// - Parameters:
///   - row: Row number to draw on
///   - widths: Column widths
///   - kind: Border type ("top", "mid", "bot")
public func drawHorizontalLine(row: Int, widths: [Int], kind: String = "mid") {
    move(CursesInt(row), 0)

    let dimCode = ANSIColor.dim

    var line = dimCode

    let (left, mid, right): (String, String, String)
    switch kind {
    case "top":
        (left, mid, right) = (BoxChars.topLeft, BoxChars.topTee, BoxChars.topRight)
    case "mid":
        (left, mid, right) = (BoxChars.leftTee, BoxChars.cross, BoxChars.rightTee)
    case "bot":
        (left, mid, right) = (BoxChars.bottomLeft, BoxChars.bottomTee, BoxChars.bottomRight)
    default:
        (left, mid, right) = (BoxChars.leftTee, BoxChars.cross, BoxChars.rightTee)
    }

    line += left

    for (i, w) in widths.enumerated() {
        line += String(repeating: BoxChars.horizontal, count: w)
        if i < widths.count - 1 {
            line += mid
        }
    }

    line += right + ANSIColor.reset

    addstr(line)
}

// MARK: - Table Row Drawing

/// Draw a table row with cell values
/// - Parameters:
///   - row: Row number
///   - widths: Column widths
///   - cells: Cell text values
///   - attrs: Optional per-cell attributes (default: no special attributes)
///   - isSelected: Whether this row is selected (cyan borders)
public func drawTableRow(row: Int, widths: [Int], cells: [String], attrs: [Chtype]? = nil, isSelected: Bool = false) {
    move(CursesInt(row), 0)

    let dimCode = ANSIColor.dim
    let selColor = ANSIColor.cyan
    let borderColor = isSelected ? selColor : dimCode

    var line = borderColor + BoxChars.vertical + ANSIColor.reset

    for (i, cell) in cells.enumerated() {
        let text = cell  // Already padded by caller

        // Apply attribute if provided
        if let attr = attrs?[i] {
            line += withAttr(text, attr)
        } else if isSelected {
            // Selected row: bold for certain columns
            line += ANSIColor.bold + text + ANSIColor.reset
        } else {
            line += text
        }

        line += borderColor + BoxChars.vertical + ANSIColor.reset
    }

    addstr(line)
}

// MARK: - Table Header Drawing

/// Draw table header row with bold/underline headers (no background)
public func drawTableHeader(row: Int, widths: [Int], columns: [TableColumn] = defaultColumns) {
    // Build header line with underline + bold styling
    move(CursesInt(row), 0)

    let borderColor = ANSIColor.dim

    // Build line with headers
    var line = borderColor + BoxChars.vertical + ANSIColor.reset

    for (_, (w, col)) in zip(widths, columns).enumerated() {
        // Pad header to match column width (headers are ASCII, but use same function for consistency)
        let padded = padToDisplayWidth(col.header, width: w)
        // Apply bold + underline to header
        line += ANSIColor.bold + ANSIColor.underline + padded + ANSIColor.reset
        line += borderColor + BoxChars.vertical + ANSIColor.reset
    }

    addstr(line)
}

// MARK: - Helper Functions

/// Format relative time (e.g., "5m ago")
public func formatRelativeTime(_ date: Date) -> String {
    let diff = Date().timeIntervalSince(date)
    if diff < 0 { return "just now" }
    else if diff < 60 { return "just now" }
    else if diff < 3600 { return "\(Int(diff / 60))m ago" }
    else if diff < 86400 { return "\(Int(diff / 3600))h ago" }
    else { return "\(Int(diff / 86400))d ago" }
}

/// Format cost in USD
public func formatCost(_ usd: Double) -> String {
    if usd < 0.01 { return "$0" }
    else if usd < 1 { return String(format: "$%.2f", usd) }
    else if usd < 10 { return String(format: "$%.1f", usd) }
    else { return String(format: "$%.0f", usd) }
}

/// Format token count
public func formatTokens(_ n: Int) -> String {
    if n < 1000 { return String(n) }
    else if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000) }
    else { return String(format: "%.1fM", Double(n) / 1_000_000) }
}

/// Truncate path to show only last component
public func shortPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    return url.lastPathComponent
}

/// Convert multi-line text to single line
public func oneline(_ text: String) -> String {
    text.split(separator: "\n").joined(separator: " ")
        .split(separator: " ").joined(separator: " ")
}

/// Short ID (first 8 characters)
public func shortId(_ id: String) -> String {
    String(id.prefix(8))
}

// MARK: - Display Width Padding

/// Pad string to specified display width (accounts for emoji/CJK characters)
public func padToDisplayWidth(_ text: String, width: Int, padChar: String = " ") -> String {
    let displayWidth = calcDisplayWidth(text)
    if displayWidth >= width {
        return text
    }
    let padding = String(repeating: padChar, count: width - displayWidth)
    return text + padding
}

/// Calculate display width of string (emoji/CJK = 2, others = 1)
public func calcDisplayWidth(_ text: String) -> Int {
    var width = 0
    for char in text {
        if char.isEmoji || char.isCJK {
            width += 2
        } else {
            width += 1
        }
    }
    return width
}

private extension Character {
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        // ASCII chars (0x00-0x7F) are never displayed as emoji, even if they have emoji variants
        if scalar.value < 0x80 { return false }
        // Check for actual emoji presentation
        return scalar.properties.isEmoji && scalar.properties.generalCategory != .decimalNumber
    }

    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) || // CJK Unified Ideographs
               (0x3000...0x303F).contains(scalar.value) || // CJK Symbols and Punctuation
               (0xFF00...0xFFEF).contains(scalar.value)    // Halfwidth and Fullwidth Forms
    }
}

// MARK: - Column Equatable Conformance

extension TableColumn: Equatable {
    public static func == (lhs: TableColumn, rhs: TableColumn) -> Bool {
        return lhs.key == rhs.key
    }
}
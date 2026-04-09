import Foundation
import Darwin

// MARK: - Curses-like Constants (for ANSI terminal control)

public typealias Chtype = UInt32
public typealias CursesInt = Int32

// Colors (ANSI codes)
public let COLOR_BLACK: Int32 = 0
public let COLOR_RED: Int32 = 1
public let COLOR_GREEN: Int32 = 2
public let COLOR_YELLOW: Int32 = 3
public let COLOR_BLUE: Int32 = 4
public let COLOR_MAGENTA: Int32 = 5
public let COLOR_CYAN: Int32 = 6
public let COLOR_WHITE: Int32 = 7

// Attributes
public let A_NORMAL: Chtype = 0
public let A_BOLD: Chtype = 1
public let A_DIM: Chtype = 2
public let A_REVERSE: Chtype = 7

// Key codes (after parsing escape sequences)
public let KEY_DOWN: CursesInt = 0x102
public let KEY_UP: CursesInt = 0x103
public let KEY_LEFT: CursesInt = 0x104
public let KEY_RIGHT: CursesInt = 0x105
public let KEY_ENTER: CursesInt = 0x157

// MARK: - Terminal Control Class

/// Terminal control with raw mode and ANSI output
public class Terminal {
    private var originalTermios: termios?
    private var rows: Int = 24
    private var cols: Int = 80

    // Singleton for global access
    public static var current: Terminal?

    public var LINES: Int { rows }
    public var COLS: Int { cols }

    // MARK: - Initialization

    public init() {
        updateSize()
    }

    // MARK: - Terminal Size

    public func updateSize() {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            rows = Int(w.ws_row) > 0 ? Int(w.ws_row) : 24
            cols = Int(w.ws_col) > 0 ? Int(w.ws_col) : 80
        }
    }

    // MARK: - Raw Mode

    public func enableRawMode() {
        guard isatty(STDIN_FILENO) == 1 else { return }

        var raw = termios()
        if tcgetattr(STDIN_FILENO, &raw) == 0 {
            originalTermios = raw
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            raw.c_cc.16 = 0  // VMIN
            raw.c_cc.17 = 1  // VTIME (100ms timeout)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
    }

    public func disableRawMode() {
        if var orig = originalTermios {
            tcsetattr(STDIN_FILENO, TCSANOW, &orig)
        }
    }

    // MARK: - Screen Control

    /// Enter alternate screen buffer (full screen mode)
    public func enterAlternateScreen() {
        print("\u{1B}[?1049h", terminator: "")  // Enable alternate screen buffer
    }

    /// Exit alternate screen buffer (restore original screen)
    public func exitAlternateScreen() {
        print("\u{1B}[?1049l", terminator: "")  // Disable alternate screen buffer
    }

    public func clear() {
        print("\u{1B}[2J\u{1B}[H", terminator: "")
    }

    public func refresh() {
        fflush(stdout)
    }

    public func hideCursor() {
        print("\u{1B}[?25l", terminator: "")
    }

    public func showCursor() {
        print("\u{1B}[?25h", terminator: "")
    }

    // MARK: - Cursor Position

    public func move(_ y: Int, _ x: Int) {
        print("\u{1B}[\(y + 1);\(x + 1)H", terminator: "")
    }

    // MARK: - Output

    public func write(_ text: String) {
        print(text, terminator: "")
    }

    public func writeLine(_ y: Int, _ x: Int, _ text: String) {
        move(y, x)
        print(text, terminator: "")
    }

    // MARK: - Input

    public func readChar() -> CursesInt {
        var ch: UInt8 = 0
        let n = read(STDIN_FILENO, &ch, 1)
        if n > 0 {
            return CursesInt(ch)
        }
        return -1 // ERR
    }

    /// Read key, handling escape sequences for arrow keys
    public func readKey() -> CursesInt {
        let ch = readChar()
        if ch == 27 { // ESC
            // Check for escape sequence
            var seq: [UInt8] = [0, 0]
            let n1 = read(STDIN_FILENO, &seq[0], 1)
            let n2 = read(STDIN_FILENO, &seq[1], 1)
            if n1 > 0 && n2 > 0 && seq[0] == 91 {
                switch seq[1] {
                case 65: return KEY_UP
                case 66: return KEY_DOWN
                case 67: return KEY_RIGHT
                case 68: return KEY_LEFT
                default: break
                }
            }
            return 27 // ESC
        }
        return ch
    }
}

// MARK: - Global Functions (curses-like API)

public func initscr() -> Terminal {
    let term = Terminal()
    Terminal.current = term
    term.enterAlternateScreen()  // Full screen mode
    term.enableRawMode()
    term.clear()
    term.hideCursor()
    return term
}

public func endwin() {
    Terminal.current?.showCursor()
    Terminal.current?.disableRawMode()
    Terminal.current?.exitAlternateScreen()  // Restore original screen
}

public func refresh() {
    Terminal.current?.refresh()
}

public func erase() {
    Terminal.current?.clear()
}

public func move(_ y: CursesInt, _ x: CursesInt) {
    Terminal.current?.move(Int(y), Int(x))
}

public func addstr(_ str: String) {
    Terminal.current?.write(str)
}

public func addnstr(_ str: String, _ n: CursesInt) {
    Terminal.current?.write(String(str.prefix(Int(n))))
}

public func getch() -> CursesInt {
    return Terminal.current?.readKey() ?? -1
}

public func timeout(_ ms: CursesInt) {
    // Timeout is handled by raw mode VTIME
}

public func curs_set(_ visibility: CursesInt) -> CursesInt {
    if visibility == 0 {
        Terminal.current?.hideCursor()
    } else {
        Terminal.current?.showCursor()
    }
    return 0
}

public var LINES: CursesInt {
    return CursesInt(Terminal.current?.LINES ?? 24)
}

public var COLS: CursesInt {
    return CursesInt(Terminal.current?.COLS ?? 80)
}

// MARK: - Color Functions

public func start_color() {}
public func use_default_colors() {}

public func init_pair(_ pair: Int16, _ f: Int32, _ b: Int32) {}

public func COLOR_PAIR(_ n: Int32) -> Chtype {
    return Chtype(n)
}

// MARK: - Attribute Functions

public func attrset(_ attrs: Chtype) {
    // Map attributes to ANSI codes
    var codes = ""
    if attrs & A_BOLD != 0 { codes += "\u{1B}[1m" }
    if attrs & A_DIM != 0 { codes += "\u{1B}[2m" }
    if attrs & A_REVERSE != 0 { codes += "\u{1B}[7m" }
    if codes.isEmpty { codes = "\u{1B}[0m" }
    Terminal.current?.write(codes)
}

public func attron(_ attrs: Chtype) {
    attrset(attrs)
}

public func attroff(_ attrs: Chtype) {
    Terminal.current?.write("\u{1B}[0m")
}

// MARK: - Color Helper

/// Set foreground color
public func setColor(_ color: Int32) {
    Terminal.current?.write("\u{1B}[3\(color)m")
}

/// Set background color
public func setBgColor(_ color: Int32) {
    Terminal.current?.write("\u{1B}[4\(color)m")
}

/// Reset to default colors
public func resetColor() {
    Terminal.current?.write("\u{1B}[0m")
}
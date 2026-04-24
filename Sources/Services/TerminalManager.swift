import Foundation

/// Terminal 管理器 - 用于激活 Terminal 并导航到指定目录
/// 支持多种 Terminal 应用：Terminal.app, iTerm2, Ghostty, tmux
class TerminalManager {

    // MARK: - 智能跳转

    /// 智能跳转：优先使用存储的终端信息，然后尝试窗口匹配
    static func smartActivateTerminal(forSession session: AISession) {
        NSLog("[TerminalManager] === Starting smart activate for session ===")
        NSLog("[TerminalManager] Session ID: \(session.id), PID: \(session.pid), cwd: \(session.cwd)")
        NSLog("[TerminalManager] Project name: \(session.projectName)")
        NSLog("[TerminalManager] Terminal info: tty=\(session.tty ?? "nil"), termProgram=\(session.termProgram ?? "nil"), termBundleId=\(session.termBundleId ?? "nil"), cmuxSocket=\(session.cmuxSocketPath ?? "nil"), cmuxSurface=\(session.cmuxSurfaceId ?? "nil")")

        // 方法0：优先检测 cmux（cmux 有专用 socket 和 surface 信息）
        if let cmuxSocket = session.cmuxSocketPath, !cmuxSocket.isEmpty, session.termProgram == "cmux" || session.termBundleId == "cmux" {
            NSLog("[TerminalManager] Method 0: Detected cmux with socket: \(cmuxSocket)")
            activateCmuxWithSocket(cmuxSocket, sessionId: session.id, cmuxSurfaceId: session.cmuxSurfaceId)
            return
        }

        // 方法0.5：优先使用 AISession 自带的终端信息（由调用方从 SessionData.terminalInfo/ghosttyTerminalId 填充）
        // 旧逻辑从 SessionTerminalStore.shared 取，但该 store 并未针对所有 session 同步；
        // AISession 才是权威来源。只有当 AISession 字段为空时才回退到 SessionTerminalStore。
        let effTerm = session.termProgram ?? SessionTerminalStore.shared.get(sessionId: session.id)?.termProgram
        let effBundle = session.termBundleId ?? SessionTerminalStore.shared.get(sessionId: session.id)?.termBundleId
        let effTty = session.tty ?? SessionTerminalStore.shared.get(sessionId: session.id)?.tty
        let effCmuxSocket = session.cmuxSocketPath ?? SessionTerminalStore.shared.get(sessionId: session.id)?.cmuxSocketPath
        let effCmuxSurface = session.cmuxSurfaceId ?? SessionTerminalStore.shared.get(sessionId: session.id)?.cmuxSurfaceId

        if effTerm != nil || effTty != nil || effCmuxSocket != nil {
            NSLog("[TerminalManager] Method 0.5: Using effective info: term=\(effTerm ?? "nil"), tty=\(effTty ?? "nil"), ghosttyId=\(session.ghosttyTerminalId ?? "nil"), cmuxSocket=\(effCmuxSocket ?? "nil")")

            // cmux 优先
            if let cmuxSocket = effCmuxSocket, !cmuxSocket.isEmpty, effTerm == "cmux" || effBundle == "cmux" {
                NSLog("[TerminalManager] Method 0.5: cmux with socket: \(cmuxSocket)")
                activateCmuxWithSocket(cmuxSocket, sessionId: session.id, cmuxSurfaceId: effCmuxSurface)
                return
            }

            // Ghostty / iTerm2: 使用 TerminalJumper 精确跳转（会用 ghosttyTerminalId / marker race）
            if let termProgram = effTerm {
                let lower = termProgram.lowercased()
                if lower.contains("ghostty") || lower.contains("iterm") {
                    NSLog("[TerminalManager] Method 0.5: Using TerminalJumper for \(termProgram)")
                    Task {
                        _ = await TerminalJumper.shared.jump(to: session)
                    }
                    return
                }
            }

            // 其他终端
            if let tty = effTty, let termProgram = effTerm {
                if let terminalApp = detectTerminalApp(from: termProgram, bundleId: effBundle) {
                    NSLog("[TerminalManager] Method 0.5: Detected terminal app: \(terminalApp.rawValue)")
                    activateTerminal(app: terminalApp, tty: tty)
                    return
                }
            }
        }

        NSLog("[TerminalManager] No effective terminal info on AISession, falling back to detection methods")

        // 尝试找到已存在的窗口（原有逻辑）
        if let windowInfo = findWindowForSession(session) {
            if windowInfo.activationDone {
                NSLog("[TerminalManager] Activation already completed, skipping activateWindow")
                return
            }
            NSLog("[TerminalManager] Found window info: app=\(windowInfo.app.rawValue), windowIndex=\(windowInfo.windowIndex ?? -1)")
            activateWindow(windowInfo)
        } else {
            NSLog("[TerminalManager] No window found, activating running terminal")
            // 找不到窗口时，激活正在运行的终端应用
            activateRunningTerminal()
        }
    }

    /// 使用 cmux socket 激活（cmux 专用）
    /// 优先使用已有的 surfaceRef + workspaceRef（避免重复查询），否则回退到按 sessionId 查找
    private static func activateCmuxWithSocket(_ socketPath: String, sessionId: String, cmuxSurfaceId: String?, surfaceRef: String? = nil, workspaceRef: String? = nil) {
        NSLog("[TerminalManager] activateCmuxWithSocket: socket=\(socketPath), sessionId=\(sessionId), cmuxSurfaceId=\(cmuxSurfaceId ?? "nil")")

        // 如果调用者已经找到了 surface，直接使用（不重新查询）
        if let surf = surfaceRef, let ws = workspaceRef {
            activateCmuxSurface(socketPath: socketPath, surfaceRef: surf, workspaceRef: ws)
            return
        }

        // 通过 session id 在所有 workspace 中查找对应的 surface
        if let (surfaceRef, workspaceRef) = findCmuxSurfaceBySessionId(socketPath: socketPath, sessionId: sessionId) {
            NSLog("[TerminalManager] Found cmux surface: \(surfaceRef) in workspace: \(workspaceRef)")
            activateCmuxSurface(socketPath: socketPath, surfaceRef: surfaceRef, workspaceRef: workspaceRef)
            return
        }

        // 找不到 surface，只激活应用
        NSLog("[TerminalManager] Could not locate cmux surface, activating app only")
        activateCmux()
    }

    /// 切换到指定的 cmux workspace
    private static func selectCmuxWorkspace(socketPath: String, workspaceRef: String) {
        NSLog("[TerminalManager] Selecting cmux workspace: \(workspaceRef)")

        let task = Process()
        task.launchPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        var env = ProcessInfo.processInfo.environment
        env["CMUX_SOCKET_PATH"] = socketPath
        task.environment = env
        task.arguments = ["select-workspace", "--workspace", workspaceRef]

        do {
            try task.run()
            task.waitUntilExit()
            NSLog("[TerminalManager] Selected workspace \(workspaceRef)")
        } catch {
            NSLog("[TerminalManager] Failed to select workspace: \(error)")
        }
    }

    /// 用 cmux tree --all 一次性获取所有 surface 信息（包含 workspace 层级）
    /// 返回 [(workspaceRef, surfaceRef, title, tty)]
    private static func listAllCmuxSurfaces(socketPath: String) -> [(workspaceRef: String, surfaceRef: String, title: String, tty: String?)]? {
        let task = Process()
        task.launchPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        var env = ProcessInfo.processInfo.environment
        env["CMUX_SOCKET_PATH"] = socketPath
        task.environment = env
        task.arguments = ["tree", "--all"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            var results: [(workspaceRef: String, surfaceRef: String, title: String, tty: String?)] = []
            var currentWorkspace: String?

            for line in output.split(separator: "\n") {
                let lineStr = String(line)

                // 匹配 workspace 行: ├── workspace workspace:1 "Title"
                if let wsMatch = lineStr.range(of: "workspace:(\\S+)", options: .regularExpression) {
                    currentWorkspace = String(lineStr[wsMatch])
                    continue
                }

                // 匹配 surface 行: │   ├── surface surface:3 [terminal] "title" [selected] tty=ttys000
                guard let ws = currentWorkspace else { continue }
                if let surfMatch = lineStr.range(of: "surface:(\\S+)", options: .regularExpression),
                   lineStr.contains("[terminal]") {
                    let surfaceRef = String(lineStr[surfMatch])

                    // 提取标题: 引号内的内容
                    var title = ""
                    if let quoteRange = lineStr.range(of: "\"([^\"]*)\"", options: .regularExpression) {
                        let raw = String(lineStr[quoteRange])
                        // 去掉引号
                        title = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }

                    // 提取 tty（如果有）
                    var tty: String?
                    if let ttyMatch = lineStr.range(of: "tty=(\\S+)", options: .regularExpression) {
                        tty = String(lineStr[ttyMatch])
                    }

                    results.append((ws, surfaceRef, title, tty))
                }
            }

            return results
        } catch {
            NSLog("[TerminalManager] Failed to run cmux tree --all: \(error)")
            return nil
        }
    }

    /// 通过 session id 在 cmux 所有 workspace 中查找 surface（使用单次 tree --all 查询）
    /// 返回 (surfaceRef, workspaceRef)
    private static func findCmuxSurfaceBySessionId(socketPath: String, sessionId: String) -> (String, String)? {
        NSLog("[TerminalManager] findCmuxSurfaceBySessionId: socket=\(socketPath), sessionId=\(sessionId)")

        guard let surfaces = listAllCmuxSurfaces(socketPath: socketPath) else {
            NSLog("[TerminalManager] Failed to list cmux surfaces")
            return nil
        }

        // cmux 标题格式: "meee2 · 任务描述 · 67cfc8da-a755-41"
        // 完整 sessionId: "67cfc8da-a755-41ef-a8ad-5386171fe14f"
        // cmux 显示前 16 位: "67cfc8da-a755-41" (8+1+4+1+2=16)
        let shortPrefix16 = String(sessionId.prefix(16)) // "67cfc8da-a755-41"
        let shortPrefix13 = String(sessionId.prefix(13)) // "67cfc8da-a755" (fallback)
        let shortId8 = String(sessionId.prefix(8))       // "67cfc8da" (last fallback)

        for (ws, surf, title, _) in surfaces {
            // 优先匹配最长的前缀
            if title.contains(shortPrefix16) {
                NSLog("[TerminalManager] Found surface \(surf) in \(ws) for session \(sessionId) (matched 16-char prefix)")
                return (surf, ws)
            }
            if title.contains(shortPrefix13) {
                NSLog("[TerminalManager] Found surface \(surf) in \(ws) for session \(sessionId) (matched 13-char prefix)")
                return (surf, ws)
            }
            if title.contains(shortId8) {
                NSLog("[TerminalManager] Found surface \(surf) in \(ws) for session \(sessionId) (matched 8-char prefix)")
                return (surf, ws)
            }
        }

        NSLog("[TerminalManager] No matching surface found in \(surfaces.count) surfaces")
        return nil
    }

    /// 通过 cwd 在 cmux 中查找对应的 surface（使用单次 tree --all 查询）
    private static func findCmuxSurfaceByCwd(socketPath: String, cwd: String) -> (surfaceRef: String, workspaceRef: String)? {
        NSLog("[TerminalManager] findCmuxSurfaceByCwd: socket=\(socketPath), cwd=\(cwd)")

        guard let surfaces = listAllCmuxSurfaces(socketPath: socketPath) else {
            return nil
        }

        let cwdName = URL(fileURLWithPath: cwd).lastPathComponent

        for (ws, surf, title, _) in surfaces {
            if title.contains(cwdName) || title.contains(cwd) {
                NSLog("[TerminalManager] Found cmux surface by cwd: surface=\(surf), workspace=\(ws)")
                return (surf, ws)
            }
        }

        NSLog("[TerminalManager] No cmux surface found for cwd '\(cwdName)'")
        return nil
    }

    /// 直接激活已知 cmux surface（不重新查询，由 findWindowForSession 传入）
    private static func activateCmuxSurface(socketPath: String, surfaceRef: String, workspaceRef: String) {
        NSLog("[TerminalManager] activateCmuxSurface: surface=\(surfaceRef), workspace=\(workspaceRef)")

        activateCmux()
        selectCmuxWorkspace(socketPath: socketPath, workspaceRef: workspaceRef)
        focusCmuxSurface(socketPath: socketPath, surfaceRef: surfaceRef)
    }

    /// 直接通过 cmux CLI 聚焦到指定 surface
    private static func focusCmuxSurface(socketPath: String, surfaceRef: String) {
        NSLog("[TerminalManager] Focus cmux surface via CLI: \(surfaceRef)")

        let task = Process()
        task.launchPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        var env2 = ProcessInfo.processInfo.environment
        env2["CMUX_SOCKET_PATH"] = socketPath
        task.environment = env2
        // move-surface with --focus true will focus without actually moving
        task.arguments = ["move-surface", "--surface", surfaceRef, "--focus", "true"]

        do {
            try task.run()
            task.waitUntilExit()
            NSLog("[TerminalManager] Focused cmux surface \(surfaceRef)")
        } catch {
            NSLog("[TerminalManager] Failed to focus cmux surface: \(error)")
        }
    }

    /// 从终端程序名检测终端类型
    private static func detectTerminalApp(from termProgram: String?, bundleId: String?) -> TerminalApp? {
        // 优先使用 Bundle ID 判断（最准确）
        if let bundleId = bundleId {
            switch bundleId {
            case "com.apple.Terminal": return .terminal
            case "com.googlecode.iterm2": return .iterm2
            case "com.mitchellh.ghostty": return .ghostty
            case "com.cmuxterm.app", "cmux": return .cmux
            default: break
            }
        }

        // 回退到程序名判断
        if let termProgram = termProgram?.lowercased() {
            if termProgram.contains("terminal") { return .terminal }
            if termProgram.contains("iterm") { return .iterm2 }
            if termProgram.contains("ghostty") { return .ghostty }
            if termProgram.contains("cmux") { return .cmux }
            if termProgram.contains("alacritty") { return .alacritty }
            if termProgram.contains("kitty") { return .kitty }
            if termProgram.contains("wezterm") { return .wezterm }
        }

        return nil
    }

    /// 激活指定终端（使用 tty 精确匹配）
    private static func activateTerminal(app: TerminalApp, tty: String) {
        NSLog("[TerminalManager] activateTerminal: app=\(app.rawValue), tty=\(tty)")

        switch app {
        case .terminal, .iterm2:
            // 支持 AppleScript tty 查询的终端
            if let windowIndex = findWindowWithTTY(tty, in: app) {
                NSLog("[TerminalManager] Found window by tty at index \(windowIndex)")
                activateWindow(WindowInfo(app: app, windowIndex: windowIndex, sessionName: nil))
            } else {
                NSLog("[TerminalManager] No window found by tty, activating app directly")
                activateApp(app.bundleId)
            }

        case .ghostty, .cmux:
            // 不支持 AppleScript tty 查询，直接激活应用
            NSLog("[TerminalManager] \(app.rawValue) doesn't support AppleScript tty query, activating directly")
            activateApp(app.bundleId)

        default:
            NSLog("[TerminalManager] Unknown terminal type, activating by bundle ID")
            activateApp(app.bundleId)
        }
    }

    /// 激活正在运行的终端应用（优先级：cmux > ghostty > iterm2 > terminal）
    private static func activateRunningTerminal() {
        // 检查哪些终端在运行，激活优先级最高的
        if isAppRunning("cmux") {
            NSLog("[TerminalManager] Activating cmux (running)")
            activateCmux()
        } else if isAppRunning("Ghostty") {
            NSLog("[TerminalManager] Activating Ghostty (running)")
            activateGhostty()
        } else if isAppRunning("iTerm2") {
            NSLog("[TerminalManager] Activating iTerm2 (running)")
            activateApp("com.googlecode.iterm2")
        } else if isAppRunning("Terminal") {
            NSLog("[TerminalManager] Activating Terminal (running)")
            activateApp("com.apple.Terminal")
        } else {
            // 没有终端在运行，打开默认终端
            NSLog("[TerminalManager] No terminal running, opening preferred terminal")
            activatePreferredTerminal(at: NSHomeDirectory())
        }
    }

    // MARK: - 窗口查找

    /// 窗口信息
    struct WindowInfo {
        let app: TerminalApp
        let windowIndex: Int?
        let sessionName: String?  // for tmux
        var activationDone: Bool = false  // 表示激活已完成，不需要再调用 activateWindow
    }

    /// 支持的 Terminal 应用
    enum TerminalApp: String, CaseIterable {
        case terminal = "Terminal"
        case iterm2 = "iTerm2"
        case ghostty = "Ghostty"
        case alacritty = "Alacritty"
        case kitty = "kitty"
        case wezterm = "WezTerm"
        case cmux = "cmux"

        var bundleId: String {
            switch self {
            case .terminal: return "com.apple.Terminal"
            case .iterm2: return "com.googlecode.iterm2"
            case .ghostty: return "com.mitchellh.ghostty"
            case .alacritty: return "io.alacritty"
            case .kitty: return "net.kovidgoyal.kitty"
            case .wezterm: return "com.github.wez.wezterm"
            case .cmux: return "cmux"  // cmux bundle id
            }
        }
    }

    /// 查找与 session 关联的 Terminal 窗口
    private static func findWindowForSession(_ session: AISession) -> WindowInfo? {
        NSLog("[TerminalManager] findWindowForSession: PID=\(session.pid)")

        // 方法1：通过进程父链判断终端类型
        NSLog("[TerminalManager] Method 1: Checking parent process chain...")
        if let terminalApp = getTerminalAppForPID(session.pid) {
            NSLog("[TerminalManager] Detected terminal app via parent chain: \(terminalApp.rawValue)")

            switch terminalApp {
            case .cmux:
                // cmux 特殊处理：用 cmux tree --all 一次性查找 session surface
                NSLog("[TerminalManager] Terminal is cmux, searching for surface by session ID...")

                // 尝试默认 cmux socket
                let defaultSocket = "\(NSHomeDirectory())/Library/Application Support/cmux/cmux.sock"
                if FileManager.default.fileExists(atPath: defaultSocket) {
                    if let (surfaceRef, workspaceRef) = findCmuxSurfaceBySessionId(socketPath: defaultSocket, sessionId: session.id) {
                        NSLog("[TerminalManager] Found cmux surface \(surfaceRef) in workspace \(workspaceRef)")
                        activateCmuxWithSocket(defaultSocket, sessionId: session.id, cmuxSurfaceId: nil, surfaceRef: surfaceRef, workspaceRef: workspaceRef)
                        // 激活已完成
                        return WindowInfo(app: .cmux, windowIndex: nil, sessionName: nil, activationDone: true)
                    }
                }

                // 如果 session 有 cmuxSocketPath，也尝试
                if let socketPath = session.cmuxSocketPath, socketPath != defaultSocket {
                    if let (surfaceRef, workspaceRef) = findCmuxSurfaceBySessionId(socketPath: socketPath, sessionId: session.id) {
                        NSLog("[TerminalManager] Found cmux surface \(surfaceRef) in workspace \(workspaceRef)")
                        activateCmuxWithSocket(socketPath, sessionId: session.id, cmuxSurfaceId: nil, surfaceRef: surfaceRef, workspaceRef: workspaceRef)
                        // 激活已完成
                        return WindowInfo(app: .cmux, windowIndex: nil, sessionName: nil, activationDone: true)
                    }
                }

                // 最后尝试 cwd 匹配（在当前 workspace）
                NSLog("[TerminalManager] Session ID not found, trying cwd matching...")
                if findAndActivateCmuxByCwd(forSession: session) {
                    // cwd 匹配成功，激活已完成
                    NSLog("[TerminalManager] cmux activation completed via cwd matching")
                    return WindowInfo(app: .cmux, windowIndex: nil, sessionName: nil, activationDone: true)
                }

                NSLog("[TerminalManager] No specific cmux surface found, activating cmux directly")
                return WindowInfo(app: .cmux, windowIndex: nil, sessionName: nil)

            case .terminal, .iterm2, .ghostty:
                // 获取 tty 尝试精确匹配窗口
                if let tty = getTTYForPID(session.pid) {
                    NSLog("[TerminalManager] Found tty: \(tty)")
                    if let windowIndex = findWindowWithTTY(tty, in: terminalApp) {
                        NSLog("[TerminalManager] Found window by tty at index \(windowIndex)")
                        return WindowInfo(app: terminalApp, windowIndex: windowIndex, sessionName: nil)
                    }
                }
                // 通过项目名匹配
                NSLog("[TerminalManager] Searching by project name in \(terminalApp.rawValue)...")
                if let windowIndex = findWindowWithTitle(containing: session.projectName, in: terminalApp.rawValue) {
                    NSLog("[TerminalManager] Found window by project name at index \(windowIndex)")
                    return WindowInfo(app: terminalApp, windowIndex: windowIndex, sessionName: nil)
                }
                // 直接激活该终端
                NSLog("[TerminalManager] No window found, will activate \(terminalApp.rawValue) directly")
                return WindowInfo(app: terminalApp, windowIndex: nil, sessionName: nil)

            default:
                // 其他终端直接激活
                NSLog("[TerminalManager] Other terminal type, will activate directly")
                return WindowInfo(app: terminalApp, windowIndex: nil, sessionName: nil)
            }
        }

        NSLog("[TerminalManager] Method 1 failed: Could not detect terminal via parent chain")

        // 方法2：通过 tty 查找
        NSLog("[TerminalManager] Method 2: Searching by tty...")
        if let tty = getTTYForPID(session.pid) {
            NSLog("[TerminalManager] Session tty: \(tty)")

            // 检查 tmux session
            if let tmuxSession = findTmuxSessionWithTTY(tty) {
                NSLog("[TerminalManager] Found tmux session: \(tmuxSession)")
                return WindowInfo(app: .terminal, windowIndex: nil, sessionName: tmuxSession)
            }

            // 遍历所有支持的 Terminal 应用查找 tty（只检查已运行的）
            for app in TerminalApp.allCases {
                if isAppRunning(app.rawValue) {
                    NSLog("[TerminalManager] \(app.rawValue) is running, checking tty...")
                    if let windowIndex = findWindowWithTTY(tty, in: app) {
                        NSLog("[TerminalManager] Found window in \(app.rawValue): \(windowIndex)")
                        return WindowInfo(app: app, windowIndex: windowIndex, sessionName: nil)
                    }
                } else {
                    NSLog("[TerminalManager] \(app.rawValue) is NOT running, skipping")
                }
            }
        } else {
            NSLog("[TerminalManager] Method 2 failed: Could not get tty for PID")
        }

        // 方法3：通过项目名匹配（只检查已运行的终端）
        NSLog("[TerminalManager] Method 3: Searching by project name in running terminals...")
        return findWindowByProjectName(session.projectName)
    }

    /// 通过进程父链获取终端应用类型
    private static func getTerminalAppForPID(_ pid: Int) -> TerminalApp? {
        NSLog("[TerminalManager] getTerminalAppForPID: \(pid)")

        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(pid), "-o", "ppid="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("[TerminalManager] PID \(pid) parent PID (ppid): \(output)")

            if let ppid = Int(output), ppid > 0 {
                // 递归查找父进程名称
                return getTerminalAppFromParentPID(ppid, depth: 0)
            } else {
                NSLog("[TerminalManager] Could not parse ppid from output")
            }
        } catch {
            NSLog("[TerminalManager] Failed to get parent PID: \(error)")
        }

        return nil
    }

    /// 从父进程 PID 获取终端应用
    private static func getTerminalAppFromParentPID(_ ppid: Int, depth: Int = 0) -> TerminalApp? {
        guard depth < 10 else {
            NSLog("[TerminalManager] Max recursion depth reached")
            return nil
        }

        NSLog("[TerminalManager] getTerminalAppFromParentPID: ppid=\(ppid), depth=\(depth)")

        // 获取完整命令路径
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(ppid), "-o", "command="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let commandPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("[TerminalManager] Parent PID \(ppid) command: '\(commandPath)'")

            // 匹配终端应用 - 检查路径是否包含终端名称
            // 例如: /Applications/cmux.app/Contents/MacOS/cmux
            let lowerPath = commandPath.lowercased()

            if lowerPath.contains("terminal.app") || (lowerPath.contains("/terminal") && !lowerPath.contains("tmux")) {
                NSLog("[TerminalManager] Matched: Terminal.app")
                return .terminal
            }
            if lowerPath.contains("iterm.app") || lowerPath.contains("iterm2.app") || lowerPath.contains("/iterm") {
                NSLog("[TerminalManager] Matched: iTerm2")
                return .iterm2
            }
            if lowerPath.contains("ghostty.app") || lowerPath.contains("/ghostty") {
                NSLog("[TerminalManager] Matched: Ghostty")
                return .ghostty
            }
            if lowerPath.contains("cmux.app") || lowerPath.contains("/cmux") {
                NSLog("[TerminalManager] Matched: cmux")
                return .cmux
            }
            if lowerPath.contains("/tmux") && !lowerPath.contains("cmux") {
                NSLog("[TerminalManager] Found tmux, continuing to search parent...")
                // tmux 的父进程通常是终端，继续往上找
            } else {
                NSLog("[TerminalManager] Command '\(commandPath)' not a known terminal, continuing...")
            }

            // 获取父进程的父进程
            let ppidTask = Process()
            ppidTask.launchPath = "/bin/ps"
            ppidTask.arguments = ["-p", String(ppid), "-o", "ppid="]

            let ppidPipe = Pipe()
            ppidTask.standardOutput = ppidPipe

            try ppidTask.run()
            ppidTask.waitUntilExit()

            let ppidData = ppidPipe.fileHandleForReading.readDataToEndOfFile()
            let ppidOutput = String(data: ppidData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("[TerminalManager] Parent of \(ppid) (next ppid): '\(ppidOutput)'")

            if let nextPpid = Int(ppidOutput), nextPpid > 0, nextPpid != ppid {
                return getTerminalAppFromParentPID(nextPpid, depth: depth + 1)
            } else {
                NSLog("[TerminalManager] No valid next ppid, stopping recursion")
            }
        } catch {
            NSLog("[TerminalManager] Failed to get process command: \(error)")
        }

        return nil
    }

    /// 检查应用是否正在运行
    private static func isAppRunning(_ appName: String) -> Bool {
        NSLog("[TerminalManager] isAppRunning: checking '\(appName)'")

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "tell application \"System Events\" to get name of every process"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let isRunning = output.lowercased().contains(appName.lowercased())
            NSLog("[TerminalManager] isAppRunning '\(appName)': \(isRunning) (processes: \(output.prefix(200)))")
            return isRunning
        } catch {
            NSLog("[TerminalManager] isAppRunning check failed: \(error)")
            return false
        }
    }

    /// 获取指定 PID 的 tty
    private static func getTTYForPID(_ pid: Int) -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-p", String(pid), "-F", "n"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            for line in output.split(separator: "\n") {
                if line.hasPrefix("n") && (line.contains("tty") || line.contains("pts")) {
                    return String(line.dropFirst())
                }
            }
        } catch {
            MLog("[TerminalManager] Failed to get TTY for PID \(pid): \(error)")
        }

        return nil
    }

    /// 在指定 Terminal 应用中查找 tty
    private static func findWindowWithTTY(_ tty: String, in app: TerminalApp) -> Int? {
        let ttyName = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        switch app {
        case .terminal:
            return findWindowWithTTYInTerminal(ttyName)
        case .iterm2:
            return findWindowWithTTYIniTerm2(ttyName)
        case .ghostty, .cmux:
            // Ghostty 和 cmux 不支持 AppleScript tty 查询
            // 使用标题匹配作为替代
            return nil
        default:
            return nil
        }
    }

    /// 在 cmux 中通过 cwd 匹配查找窗口（fallback，当 session ID 不匹配时使用）
    /// 找到后直接激活，返回 true 表示已处理，false 表示未找到
    private static func findAndActivateCmuxByCwd(forSession session: AISession) -> Bool {
        NSLog("[TerminalManager] findAndActivateCmuxByCwd for session: \(session.projectName)")

        let defaultSocket = "\(NSHomeDirectory())/Library/Application Support/cmux/cmux.sock"
        let socketPath = session.cmuxSocketPath ?? (FileManager.default.fileExists(atPath: defaultSocket) ? defaultSocket : nil)

        if let socketPath = socketPath {
            if let (surfaceRef, workspaceRef) = findCmuxSurfaceByCwd(socketPath: socketPath, cwd: session.cwd) {
                NSLog("[TerminalManager] Found cmux surface by cwd: \(surfaceRef) in \(workspaceRef)")
                activateCmuxSurface(socketPath: socketPath, surfaceRef: surfaceRef, workspaceRef: workspaceRef)
                return true
            }
        }

        NSLog("[TerminalManager] findAndActivateCmuxByCwd: No window found via cmux CLI")
        return false
    }

    /// 在 Terminal.app 中查找 tty
    private static func findWindowWithTTYInTerminal(_ tty: String) -> Int? {
        guard isAppRunning("Terminal") else { return nil }

        let script = """
        tell application "Terminal"
            set targetTTY to "\(tty)"
            repeat with i from 1 to count of windows
                try
                    set windowTTY to tty of current tab of window i
                    if windowTTY is targetTTY then
                        return i
                    end if
                end try
            end repeat
        end tell
        return 0
        """

        if let result = executeAppleScriptWithResult(script), let index = Int(result), index > 0 {
            return index
        }
        return nil
    }

    /// 在 iTerm2 中查找 tty
    private static func findWindowWithTTYIniTerm2(_ tty: String) -> Int? {
        guard isAppRunning("iTerm2") else { return nil }

        let script = """
        tell application "iTerm2"
            set targetTTY to "\(tty)"
            repeat with i from 1 to count of windows
                try
                    set sessionTTY to tty of current session of current tab of window i
                    if sessionTTY is targetTTY then
                        return i
                    end if
                end try
            end repeat
        end tell
        return 0
        """

        if let result = executeAppleScriptWithResult(script), let index = Int(result), index > 0 {
            return index
        }
        return nil
    }

    /// 通过项目名查找窗口（只检查已运行的终端）
    private static func findWindowByProjectName(_ projectName: String) -> WindowInfo? {
        NSLog("[TerminalManager] findWindowByProjectName: '\(projectName)'")

        // 尝试在 cmux 中查找（如果已运行）- 优先检查 cmux
        if isAppRunning("cmux") {
            NSLog("[TerminalManager] cmux is running, searching...")
            if let index = findWindowWithTitle(containing: projectName, in: "cmux") {
                NSLog("[TerminalManager] Found in cmux at index \(index)")
                return WindowInfo(app: .cmux, windowIndex: index, sessionName: nil)
            }
            // cmux 运行中但找不到具体窗口，仍然返回 cmux（不要 fallback 到其他终端）
            NSLog("[TerminalManager] cmux is running but no window matched, returning cmux anyway")
            return WindowInfo(app: .cmux, windowIndex: nil, sessionName: nil)
        }

        // 尝试在 Ghostty 中查找（如果已运行）
        // Ghostty 不支持 AppleScript window 查询，直接返回应用信息
        if isAppRunning("Ghostty") {
            NSLog("[TerminalManager] Ghostty is running")
            return WindowInfo(app: .ghostty, windowIndex: nil, sessionName: nil)
        }

        // 尝试在 iTerm2 中查找（如果已运行）
        if isAppRunning("iTerm2") {
            NSLog("[TerminalManager] iTerm2 is running, searching...")
            if let index = findWindowWithTitle(containing: projectName, in: "iTerm2") {
                NSLog("[TerminalManager] Found in iTerm2 at index \(index)")
                return WindowInfo(app: .iterm2, windowIndex: index, sessionName: nil)
            }
        }

        // 尝试在 Terminal.app 中查找（如果已运行）
        if isAppRunning("Terminal") {
            NSLog("[TerminalManager] Terminal is running, searching...")
            if let index = findWindowWithTitle(containing: projectName, in: "Terminal") {
                NSLog("[TerminalManager] Found in Terminal at index \(index)")
                return WindowInfo(app: .terminal, windowIndex: index, sessionName: nil)
            }
        }

        NSLog("[TerminalManager] findWindowByProjectName: No match found")
        return nil
    }

    /// 查找标题包含指定字符串的窗口
    private static func findWindowWithTitle(containing text: String, in appName: String) -> Int? {
        NSLog("[TerminalManager] findWindowWithTitle: text='\(text)', app='\(appName)'")

        // 先检查应用是否运行
        guard isAppRunning(appName) else {
            NSLog("[TerminalManager] App '\(appName)' not running, returning nil")
            return nil
        }

        // Ghostty 不支持 AppleScript window 操作，跳过
        if appName.lowercased() == "ghostty" {
            NSLog("[TerminalManager] Ghostty doesn't support AppleScript window queries, skipping")
            return nil
        }

        let escapedText = text.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "\(appName)"
            set searchText to "\(escapedText)"
            repeat with i from 1 to count of windows
                try
                    set windowTitle to name of window i
                    if windowTitle contains searchText then
                        return i
                    end if
                end try
            end repeat
        end tell
        return 0
        """

        if let result = executeAppleScriptWithResult(script), let index = Int(result), index > 0 {
            NSLog("[TerminalManager] findWindowWithTitle: Found at index \(index)")
            return index
        }
        NSLog("[TerminalManager] findWindowWithTitle: No match found")
        return nil
    }

    // MARK: - tmux 支持

    /// 查找使用指定 tty 的 tmux session
    private static func findTmuxSessionWithTTY(_ tty: String) -> String? {
        let ttyName = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        MLog("[TerminalManager] Looking for tmux session with tty: \(ttyName)")

        // 检查 tmux 是否可用
        let checkTask = Process()
        checkTask.launchPath = "/usr/bin/env"
        checkTask.arguments = ["sh", "-c", "which tmux"]
        let checkPipe = Pipe()
        checkTask.standardOutput = checkPipe

        do {
            try checkTask.run()
            checkTask.waitUntilExit()
            let data = checkPipe.fileHandleForReading.readDataToEndOfFile()
            guard let tmuxPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tmuxPath.isEmpty else {
                MLog("[TerminalManager] tmux not found in PATH")
                return nil
            }
            MLog("[TerminalManager] tmux path: \(tmuxPath)")
        } catch {
            MLog("[TerminalManager] Failed to check tmux: \(error)")
            return nil
        }

        // 获取所有 tmux sessions
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["sh", "-c", "tmux list-sessions -F '#{session_name}' 2>/dev/null || echo ''"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            MLog("[TerminalManager] tmux sessions: \(output)")

            let sessionNames = output.split(separator: "\n").filter { !$0.isEmpty }
            MLog("[TerminalManager] Found \(sessionNames.count) tmux sessions")

            for sessionName in sessionNames {
                let name = String(sessionName)
                MLog("[TerminalManager] Checking session: \(name)")
                if tmuxSessionHasTTY(name, tty: ttyName) {
                    MLog("[TerminalManager] Found matching session: \(name)")
                    return name
                }
            }
        } catch {
            MLog("[TerminalManager] Failed to list tmux sessions: \(error)")
        }

        return nil
    }

    /// 检查 tmux session 是否有使用指定 tty 的 pane
    private static func tmuxSessionHasTTY(_ session: String, tty: String) -> Bool {
        let ttyName = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let shortTTY = ttyName.replacingOccurrences(of: "/dev/", with: "")

        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["sh", "-c", "tmux list-panes -t '\(session)' -F '#{pane_tty}' 2>/dev/null || echo ''"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            MLog("[TerminalManager] Session '\(session)' pane ttys: \(output)")
            MLog("[TerminalManager] Looking for tty: \(ttyName) or \(shortTTY)")

            // 检查完整路径或短名称
            for line in output.split(separator: "\n") {
                let paneTTY = String(line)
                if paneTTY == ttyName || paneTTY == shortTTY || paneTTY.contains(shortTTY) {
                    MLog("[TerminalManager] Match found! pane tty: \(paneTTY)")
                    return true
                }
            }
        } catch {
            MLog("[TerminalManager] Failed to list panes for session \(session): \(error)")
        }

        return false
    }

    /// 激活 tmux session
    private static func activateTmuxSession(_ sessionName: String) {
        // 检查是否有 tmux 客户端连接
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["sh", "-c", "tmux attach -t '\(sessionName)' 2>/dev/null || tmux new -s '\(sessionName)'"]

        do {
            try task.run()
        } catch {
            MLog("[TerminalManager] Failed to activate tmux session: \(error)")
        }
    }

    // MARK: - 窗口激活

    /// 激活指定的窗口
    private static func activateWindow(_ info: WindowInfo) {
        NSLog("[TerminalManager] activateWindow: app=\(info.app.rawValue), windowIndex=\(info.windowIndex ?? -1), sessionName=\(info.sessionName ?? "nil")")

        switch info.app {
        case .terminal:
            if let index = info.windowIndex {
                NSLog("[TerminalManager] Activating Terminal window \(index)")
                activateTerminalWindow(index: index)
            } else if let session = info.sessionName {
                NSLog("[TerminalManager] Activating tmux session \(session)")
                activateTmuxSession(session)
            } else {
                NSLog("[TerminalManager] Activating Terminal app directly")
                activateApp("com.apple.Terminal")
            }

        case .iterm2:
            if let index = info.windowIndex {
                NSLog("[TerminalManager] Activating iTerm2 window \(index)")
                activateiTerm2Window(index: index)
            } else {
                NSLog("[TerminalManager] Activating iTerm2 app directly")
                activateApp("com.googlecode.iterm2")
            }

        case .ghostty:
            NSLog("[TerminalManager] Activating Ghostty")
            activateGhostty()

        case .cmux:
            if let index = info.windowIndex {
                NSLog("[TerminalManager] Activating cmux window \(index)")
                activateCmuxWindow(index: index)
            } else {
                NSLog("[TerminalManager] Activating cmux app directly")
                activateCmux()
            }

        default:
            NSLog("[TerminalManager] Activating \(info.app.rawValue) by bundle ID")
            activateApp(info.app.bundleId)
        }
    }

    /// 激活 cmux 应用
    private static func activateCmux() {
        NSLog("[TerminalManager] activateCmux: using 'open -a cmux'")
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "cmux"]

        do {
            try task.run()
            NSLog("[TerminalManager] cmux activated successfully")
        } catch {
            NSLog("[TerminalManager] Failed to activate cmux: \(error)")
        }
    }

    /// 激活 cmux 的指定窗口
    private static func activateCmuxWindow(index: Int) {
        // cmux 不支持 set index，使用 System Events 来激活特定窗口
        let script = """
        tell application "cmux"
            activate
        end tell
        delay 0.1
        tell application "System Events"
            tell process "cmux"
                set frontmost to true
                try
                    perform action "AXRaise" of window \(index)
                end try
            end tell
        end tell
        """

        NSLog("[TerminalManager] Executing AppleScript for cmux window \(index)")
        executeAppleScript(script)
    }

    /// 激活 Terminal.app 的指定窗口
    private static func activateTerminalWindow(index: Int) {
        let script = """
        tell application "Terminal"
            activate
            set index of window \(index) to 1
        end tell
        """

        executeAppleScript(script)
    }

    /// 激活 iTerm2 的指定窗口
    private static func activateiTerm2Window(index: Int) {
        let script = """
        tell application "iTerm2"
            activate
            select window \(index)
        end tell
        """

        executeAppleScript(script)
    }

    /// 激活 Ghostty
    private static func activateGhostty() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "Ghostty"]

        do {
            try task.run()
        } catch {
            MLog("[TerminalManager] Failed to activate Ghostty: \(error)")
        }
    }

    /// 通过 bundle ID 激活应用
    private static func activateApp(_ bundleId: String) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-b", bundleId]

        do {
            try task.run()
        } catch {
            MLog("[TerminalManager] Failed to activate app \(bundleId): \(error)")
        }
    }

    // MARK: - 基础方法

    /// 激活 Terminal 应用并在新 tab 中导航到指定目录
    static func activateTerminal(at path: String) {
        let script = """
        tell application "Terminal"
            activate
            if (count of windows) is 0 then
                do script "cd '\(path)'"
            else
                tell window 1
                    do script "cd '\(path)'" in (make new tab)
                end tell
            end if
        end tell
        """

        executeAppleScript(script)
    }

    /// 激活 iTerm2 并导航到指定目录
    static func activateITerm2(at path: String) {
        let script = """
        tell application "iTerm2"
            activate
            tell current window
                create tab with default profile
                tell current session
                    write text "cd '\(path)'"
                end tell
            end tell
        end tell
        """

        executeAppleScript(script)
    }

    /// 激活 Ghostty 并导航到指定目录
    static func activateGhostty(at path: String) {
        // Ghostty 使用命令行参数
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "Ghostty", "--args", "--working-directory=\(path)"]

        do {
            try task.run()
        } catch {
            MLog("[TerminalManager] Failed to activate Ghostty: \(error)")
        }
    }

    /// 检查 iTerm2 是否已安装
    static func isITerm2Installed() -> Bool {
        isAppInstalled(bundleId: "com.googlecode.iterm2")
    }

    /// 检查 Ghostty 是否已安装
    static func isGhosttyInstalled() -> Bool {
        isAppInstalled(bundleId: "com.mitchellh.ghostty")
    }

    /// 检查应用是否已安装
    private static func isAppInstalled(bundleId: String) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/mdfind"
        task.arguments = ["kMDItemCFBundleIdentifier == '\(bundleId)'"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return !output.isEmpty
        } catch {
            return false
        }
    }

    /// 使用用户偏好的 Terminal 应用
    static func activatePreferredTerminal(at path: String) {
        if isGhosttyInstalled() {
            activateGhostty(at: path)
        } else if isITerm2Installed() {
            activateITerm2(at: path)
        } else {
            activateTerminal(at: path)
        }
    }

    // MARK: - AppleScript 执行

    /// 执行 AppleScript（无返回值）
    private static func executeAppleScript(_ script: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            MLog("[TerminalManager] AppleScript execution failed: \(error)")
        }
    }

    /// 执行 AppleScript 并返回结果
    private static func executeAppleScriptWithResult(_ script: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            MLog("[TerminalManager] AppleScript execution failed: \(error)")
            return nil
        }
    }
}

# meee2 - macOS 灵动岛 AI 助手监控工具

meee2 是一款 macOS 原生应用，将 AI 编程助手的状态以 **Dynamic Island（灵动岛）** 的形式展示在屏幕顶部。用户无需切换窗口，即可实时了解 Claude CLI、Cursor 等 AI 助手的工作状态，并直接在灵动岛中进行权限审批等交互操作。

---

# 👤 Human Read（用户指南）

## 功能特性

### 1. 实时状态监控
- **Session 追踪**：自动检测并监控所有活跃的 AI 助手会话
- **状态展示**：实时显示当前正在执行的工具、任务进度、运行时长
- **多会话管理**：支持同时监控多个 AI 会话，按活跃度排序
- **Plugin 分类**：底部 Tab 快速过滤不同插件的 session

### 2. 权限审批交互
- **即时通知**：当 Claude CLI 需要用户授权时，灵动岛自动弹出提示
- **快捷操作**：直接在灵动岛中点击 **Allow / Deny** 按钮完成审批
- **详细信息**：显示 toolInput 内容和 Markdown 格式化的请求详情
- **无需切换**：无需回到终端窗口，即可完成权限决策

### 3. 智能 Terminal 跳转
- 点击 "Open" 按钮自动跳转到对应的 Terminal 窗口/tab
- 支持 Ghostty、iTerm2、Terminal.app、tmux、cmux 等多种终端

### 4. 支持的 AI 助手

| AI 助手 | 状态 | 主题色 |
|---------|------|--------|
| Claude CLI | ✅ 完整支持 | 橘色 |
| Cursor | ✅ 插件支持 | 蓝色 |
| OpenClaw | ✅ 插件支持 | 红色 |

### 5. 事件音效系统
- 支持为不同事件配置不同的系统音效
- Session 开始/结束、权限请求、任务完成等事件可单独配置

---

## 安装

### 方式一：下载预编译版本

从 [GitHub Releases](https://github.com/tianqixinxi/meee2/releases) 下载最新的 `.dmg` 文件，拖拽到 Applications 文件夹安装。

当前最新版本：**v0.1.0**

### 方式二：自行编译
```bash
# 克隆仓库
git clone https://github.com/tianqixinxi/meee2.git
cd meee2

# 编译
swift build -c release

# 产物位于 .build/release/meee2
# 可将其打包为 .app 或直接运行
```

---

## 配置

### 1. Claude CLI Hooks 配置

在 `~/.claude/settings.json` 中添加 hooks 配置：

```json
{
  "hooks": {
    "SessionStart": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "PreToolUse": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "PostToolUse": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "PermissionRequest": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "Notification": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "Stop": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "UserPromptSubmit": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }]
  }
}
```

### 2. 启动 meee2

首次启动时，meee2 会：
1. 创建 `~/.meee2/` 配置目录
2. 启动 Unix Domain Socket 服务器 (`/tmp/meee2.sock`)
3. 加载内置和用户插件

### 3. 插件安装

将插件动态库放置在 `~/.meee2/plugins/` 目录：

```
~/.meee2/plugins/
├── my-plugin/
│   ├── MyPlugin.dylib
│   └── plugin.json
└── ...
```

**内置插件**（Cursor）已随主程序自动安装，无需手动配置。

**插件开发**：参考 `plugin-template/` 目录和 `docs/PLUGIN_DEVELOPMENT.md` 创建自定义插件。

---

## 使用方法

### 紧凑视图
灵动岛默认显示在屏幕顶部中央，展示当前最活跃的 session 状态：

```
┌─────────────────────────────────┐
│  ●  my-project   Running...     │
└─────────────────────────────────┘
```

### 展开视图
点击灵动岛可展开查看所有 sessions：

```
┌───────────────────────────────────────────────┐
│  Sessions                            3  [▼]  │
├───────────────────────────────────────────────┤
│                                               │
│  ┌─────────────────────────────────────────┐ │
│  │ ● Claude  [Permission] [Ignore] [Open] │ │
│  │                                         │ │
│  │ 需要确认: Bash                          │ │
│  │ tool_input:                             │ │
│  │   command: "rm -rf /tmp/test"          │ │
│  └─────────────────────────────────────────┘ │
│                                               │
│  ● Cursor    my-project    Idle              │
│  ● OpenClaw  workspace     Running           │
│                                               │
│  [All] [Claude] [Cursor] [OpenClaw]          │  ← Plugin Tab Filter
└───────────────────────────────────────────────┘
```

### 快捷操作
- **Allow/Deny**：审批 Claude CLI 的权限请求
- **Ignore**：忽略当前通知，收起灵动岛
- **Open**：跳转到对应的 Terminal tab

### 设置
点击菜单栏图标 → Settings，可配置：
- 刷新间隔
- 音效开关
- 插件启用/禁用
- 屏幕位置

---

## FAQ

### Q: 为什么灵动岛没有显示 Claude session？
确保：
1. Claude CLI hooks 已正确配置
2. meee2 正在运行
3. Claude CLI session 目录存在 (`~/.claude/sessions/`)

### Q: 权限审批后 Claude CLI 没有响应？
检查 Console.app 中 `[HookSocketServer]` 的日志，确认 socket 通信正常。

### Q: 点击 Open 没有跳转到正确的 Terminal？
确保 Terminal 的 tab 标题包含项目名称，或使用支持精确跳转的终端（如 Ghostty）。

---

# 🤖 Agent Read（开发者指南）

> 本章节面向 AI 助手和开发者，包含项目架构、核心模块、API 接口等技术细节。

## 开发者文档索引

| 文档 | 内容 |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 模块划分、数据流、各子系统（hook ingress / 状态裁决 / 持久化 / 插件加载 / UI surfaces / A2A / 权限 / 终端跳转）、并发模型、文件系统布局与"屋内规矩" |
| [`docs/SCHEMAS.md`](docs/SCHEMAS.md) | 所有公共/共享类型的字段参考：Models、`SessionData`、`meee2-plugin-kit` 公共 SDK、Board HTTP DTO |
| [`docs/PLUGIN_DEVELOPMENT.md`](docs/PLUGIN_DEVELOPMENT.md) | 如何编写、打包、安装第三方插件 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 本地构建、测试、提交 PR 的完整流程 |
| [`RELEASING.md`](RELEASING.md) | 打 tag → 自动构建 DMG → GitHub Release 的完整流程 |
| [`SECURITY.md`](SECURITY.md) | 漏洞报告流程与信任边界说明 |

下文的「系统架构」「核心模块」小节是快速入门摘要；完整的内容请看 `docs/` 下的专门文档。

---

## 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                         meee2 App                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐    │
│  │ IslandView  │◄───│StatusManager │───►│ SessionMonitor  │    │
│  │  (SwiftUI)  │    │   (状态聚合)  │    │ (文件系统监控)   │    │
│  └─────────────┘    └──────┬───────┘    └─────────────────┘    │
│                            │                                    │
│                            ▼                                    │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   HookSocketServer                       │   │
│  │              (Unix Domain Socket 服务器)                 │   │
│  └─────────────────────────┬───────────────────────────────┘   │
│                            │                                    │
└────────────────────────────┼────────────────────────────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │       Claude CLI Hooks       │
              │      (/tmp/meee2.sock)       │
              └──────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        Plugin System                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │CursorPlugin  │  │OpenClawPlugin│  │  CustomPlugin│  ...     │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                 │                   │
│         └─────────────────┼─────────────────┘                   │
│                           ▼                                     │
│              ┌──────────────────────┐                           │
│              │    PluginManager     │                           │
│              │    (插件生命周期)     │                           │
│              └──────────────────────┘                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 核心模块

### 1. HookSocketServer

**文件**: `Sources/Services/HookSocketServer.swift`

Unix Domain Socket 服务器，监听 `/tmp/meee2.sock`，接收来自 Claude CLI hooks 的事件。

**支持的事件类型**：

| 事件 | Hook 名称 | 说明 | 是否需要响应 |
|------|-----------|------|-------------|
| `SessionStart` | `session_start` | 会话开始 | ❌ |
| `PreToolUse` | `pre_tool_use` | 工具执行前 | ❌ |
| `PostToolUse` | `post_tool_use` | 工具执行后 | ❌ |
| `PermissionRequest` | `permission_request` | 权限请求 | ✅ Allow/Deny |
| `Notification` | `notification` | 通知消息 | ❌ |
| `Stop` | `stop` | 任务完成 | ❌ |
| `UserPromptSubmit` | `user_prompt_submit` | 用户提交输入 | ❌ |

**Hook 事件 JSON 格式**：

```json
{
  "session_id": "abc-123-def",
  "hook_event_name": "permission_request",
  "tool_name": "Bash",
  "tool_use_id": "tool_456",
  "status": "waiting_for_approval",
  "tty": "/dev/ttys001",
  "term_program": "Ghostty",
  "cwd": "/Users/user/my-project",
  "input": "{\"command\": \"rm -rf /tmp/test\"}"
}
```

**权限响应流程**：

```swift
// 1. 接收 PermissionRequest 事件
// event.hook_event_name == "permission_request" && event.status == "waiting_for_approval"

// 2. 保存 pending permission (保持 socket 连接)
pendingPermissions[event.tool_use_id] = PendingPermission(clientSocket, event)

// 3. 用户点击 Allow/Deny
HookSocketServer.respondToPermissionBySession(sessionId, decision: "allow")

// 4. 发送 JSON 响应
// {"decision": "allow", "reason": null}

// 5. 关闭 socket 连接
```

---

### 2. SessionMonitor

**文件**: `Sources/Services/SessionMonitor.swift`

文件系统监控服务，监听 `~/.claude/sessions/` 目录。

**工作流程**：
1. 使用 `DispatchSourceFileSystemObject` 监听目录变化
2. 解析 `session.json` 文件获取 session 信息
3. 检查进程存活状态（通过 PID）
4. 合并运行时状态（保留 hooks 更新的状态）

**Session 数据结构**：

```swift
struct AISession: Identifiable {
    let id: String          // Session UUID
    let pid: Int            // 进程 ID
    let cwd: String         // 工作目录
    let startedAt: Date     // 启动时间
    let type: SessionType   // claude/cursor/openclaw/other

    var status: SessionStatus  // running/idle/completed/waiting_for_approval/error
    var currentTask: String?   // 当前任务描述
    var toolName: String?      // 当前工具名称
    var tty: String?           // 终端设备
    var termProgram: String?   // 终端程序名
}
```

**Session JSON 文件格式** (`~/.claude/sessions/{session_id}/session.json`)：

```json
{
  "id": "abc-123-def",
  "pid": 12345,
  "cwd": "/Users/user/my-project",
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:35:00Z",
  "metadata": {
    "title": "my-project"
  }
}
```

---

### 3. StatusManager

**文件**: `Sources/Services/StatusManager.swift`

状态聚合层，作为 SwiftUI 视图的数据源（`@ObservedObject`）。

**主要职责**：
- 合并 `SessionMonitor` 和 `HookSocketServer` 的数据
- 管理 `urgentSessions`（需要用户介入的会话）
- 处理权限审批操作
- 更新 `@Published` 属性触发 UI 刷新

**关键属性**：

```swift
class StatusManager: ObservableObject {
    @Published var sessions: [AISession] = []
    @Published var pluginSessions: [PluginSession] = []
    @Published var urgentSessions: [AISession] = []
    @Published var urgentPluginSessions: [PluginSession] = []
    @Published var urgentMessages: [String: String] = []  // sessionId -> message
    @Published var hasUrgentSession: Bool = false
    @Published var systemStatus: SystemStatus = .idle
    @Published var latestMessage: String = ""
}
```

---

### 4. PluginManager

**文件**: `Sources/Services/PluginManager.swift`

插件生命周期管理服务。

**功能**：
- 从 `~/.meee2/plugins/` 加载动态库（`.dylib`）
- 使用 `dlopen/dlsym` 动态加载插件
- 管理插件状态（启用/禁用）
- 聚合所有插件的 sessions

**插件加载流程**：

```swift
// 1. 扫描插件目录
let pluginDir = URL(fileURLWithPath: "~/.meee2/plugins/")

// 2. 加载动态库
let handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL)

// 3. 获取插件导出函数
let createFunc = dlsym(handle, "createPlugin")

// 4. 创建插件实例
let plugin = createFunc() as SessionPlugin

// 5. 初始化并启动
plugin.initialize()
plugin.start()
```

---

### 5. TerminalManager

**文件**: `Sources/Services/TerminalManager.swift`

智能终端跳转服务。

**跳转策略**（按优先级）：

1. **cmux**：通过 socket 路径和 surface ID 精确定位
2. **Ghostty**：使用 AppleScript 查询 `working directory`
3. **iTerm2**：使用 AppleScript 查询 session name 和 path
4. **Terminal.app**：通过 tab custom title 匹配

**Ghostty 跳转脚本**：

```applescript
tell application "Ghostty"
    set matches to every terminal whose working directory contains "/Users/user/my-project"
    if (count of matches) > 0 then
        focus (item 1 of matches)
    end if
end tell
```

---

### 6. IslandView

**文件**: `Sources/Views/IslandView.swift`

SwiftUI 视图，实现灵动岛 UI。

**状态模式**：

```swift
enum ExpandMode {
    case manual   // 用户手动点击展开
    case auto     // 因 urgent session 自动展开
    case hover    // 因鼠标悬停展开
}
```

**视图切换**：

```swift
if isExpanded {
    expandedContent  // 展开视图
} else {
    compactContent   // 紧凑视图
}
```

---

## 插件开发指南

### Meee2PluginKit 框架

**文件**: `meee2-plugin-kit/Sources/Meee2PluginKit/SessionPlugin.swift`

插件基类，定义插件协议。

**关键接口**：

```swift
open class SessionPlugin: NSObject, ObservableObject {
    // MARK: - 标识
    open var pluginId: String { "" }       // 反向域名格式
    open var displayName: String { "" }
    open var icon: String { "" }           // SF Symbol 名称
    open var themeColor: Color { .blue }
    open var version: String { "1.0.0" }
    open var helpUrl: String? { nil }

    // MARK: - 回调
    open var onSessionsUpdated: (([PluginSession]) -> Void)?
    open var onUrgentEvent: ((PluginSession, String, String?) -> Void)?

    // MARK: - 生命周期
    open func initialize() -> Bool { true }
    open func start() -> Bool { false }
    open func stop() {}
    open func cleanup() {}

    // MARK: - Session 管理
    open func getSessions() -> [PluginSession] { [] }
    open func refresh() {}

    // MARK: - 终端跳转
    open func activateTerminal(for session: PluginSession) {}

    // MARK: - 配置 UI
    open var settingsView: AnyView? { nil }
}
```

**PluginSession 结构**：

```swift
struct PluginSession: Identifiable {
    let id: String              // 唯一标识
    let pluginId: String        // 所属插件 ID
    let title: String           // 显示标题
    let status: SessionStatus   // 状态
    let startedAt: Date         // 开始时间
    var subtitle: String?       // 副标题
    var cwd: String?            // 工作目录
    var icon: String?           // 自定义图标
    var accentColor: Color?     // 自定义颜色
}
```

---

### 创建新插件

**1. 创建插件目录**：

```bash
mkdir -p my-plugin/Sources
cd my-plugin
```

**2. Package.swift**：

```swift
// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "MyPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MyPlugin", type: .dynamic, targets: ["MyPlugin"]),
    ],
    dependencies: [
        .package(name: "Meee2PluginKit", path: "../meee2/meee2-plugin-kit"),
    ],
    targets: [
        .target(
            name: "MyPlugin",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "Sources"
        ),
    ]
)
```

**3. 插件实现**：

```swift
import Meee2PluginKit
import SwiftUI

class MyPlugin: SessionPlugin {
    override var pluginId: String { "com.meee2.plugin.myplugin" }
    override var displayName: String { "My Plugin" }
    override var icon: String { "star.fill" }
    override var themeColor: Color { .purple }
    override var version: String { "1.0.0" }
    override var helpUrl: String? { "https://github.com/user/my-plugin" }

    private var timer: Timer?

    override func start() -> Bool {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            self.refresh()
        }
        return true
    }

    override func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func getSessions() -> [PluginSession] {
        // 返回当前 sessions
        return []
    }

    override func refresh() {
        let sessions = getSessions()
        onSessionsUpdated?(sessions)
    }

    override func activateTerminal(for session: PluginSession) {
        // 实现终端跳转逻辑
    }
}
```

**4. 导出函数**：

```swift
// MyPluginExport.swift
import Meee2PluginKit

@_cdecl("createPlugin")
public func createPlugin() -> UnsafeMutableRawPointer {
    let plugin = MyPlugin()
    return Unmanaged.passRetained(plugin).toOpaque()
}

@_cdecl("pluginId")
public func pluginId() -> UnsafePointer<CChar> {
    return "com.meee2.plugin.myplugin".withCString { $0 }
}
```

**5. 编译并安装**：

```bash
swift build -c release
cp .build/release/MyPlugin.dylib ~/.meee2/plugins/
```

---

## 设置存储

meee2 使用 `@AppStorage` 存储用户设置，键名前缀为插件 ID：

```swift
// 插件设置
@AppStorage("plugin_com.meee2.plugin.cursor_enabled") var enabled: Bool = true
@AppStorage("cursorRefreshInterval") var refreshInterval: Double = 10.0

// 全局设置
@AppStorage("showSessionInCompact") var showSessionInCompact: Bool = true
@AppStorage("carouselInterval") var carouselInterval: Double = 10
```

---

## 日志系统

**日志文件位置**: `~/.meee2/logs/meee2.log`

**日志格式**: `[Module] Message`

**关键日志点**：

```swift
// HookSocketServer
NSLog("[HookSocketServer] Received event: \(event.hook_event_name)")
NSLog("[HookSocketServer] Pending permission: \(toolUseId)")

// SessionMonitor
NSLog("[SessionMonitor] Found \(sessions.count) sessions")

// StatusManager
NSLog("[StatusManager] hasUrgentSession: \(hasUrgentSession)")

// PluginManager
NSLog("[PluginManager] Loaded plugin: \(pluginId)")
```

---

## 调试导出

**DebugExporter** (`Sources/Services/DebugExporter.swift`) 提供一键导出调试数据：

导出内容：
- 所有 session 数据
- 最近 100 条日志
- 插件状态
- Hook 配置

导出位置: `~/Desktop/meee2-debug-{timestamp}.json`

---

## 相关链接

- **GitHub**: https://github.com/tianqixinxi/meee2
- **Claude CLI 文档**: https://docs.anthropic.com/claude-cli
- **Plugin Kit**: `meee2-plugin-kit/` 目录

---

## License

MIT License
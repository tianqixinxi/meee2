# meee2 - macOS 灵动岛 AI 助手监控工具

## 产品简介

meee2 是一款 macOS 原生应用，将 AI 编程助手的状态以 **Dynamic Island（灵动岛）** 的形式展示在屏幕顶部。用户无需切换窗口，即可实时了解 Claude CLI、Cursor、GitHub Copilot 等 AI 助手的工作状态，并直接在灵动岛中进行权限审批等交互操作。

---

## 核心能力

### 1. 实时状态监控

- **Session 追踪**：自动检测并监控所有活跃的 AI 助手会话
- **状态展示**：实时显示当前正在执行的工具、任务进度、运行时长
- **多会话管理**：支持同时监控多个 AI 会话，按活跃度排序

### 2. 权限审批交互

- **即时通知**：当 Claude CLI 需要用户授权时，灵动岛自动弹出提示
- **快捷操作**：直接在灵动岛中点击 **Allow / Deny** 按钮完成审批
- **无需切换**：无需回到终端窗口，即可完成权限决策

### 3. 智能 Terminal 跳转

- **精确跳转**：点击 "Open" 按钮自动跳转到对应的 Terminal 窗口/tab
- **多终端支持**：支持 Ghostty、iTerm2、Terminal.app、tmux、cmux 等多种终端
- **智能匹配**：通过 tty 设备、进程 ID、窗口标题等多维度精确定位

### 4. 多 AI 助手支持

| AI 助手 | 状态 | 主题色 |
|---------|------|--------|
| Claude CLI | ✅ 完整支持 | 橙色 |
| Cursor | ✅ 插件支持 | 蓝色 |
| GitHub Copilot | ✅ 插件支持 | 紫色 |
| Aime | ✅ 插件支持 | 绿色 |
| 其他 | 🔌 可扩展 | 灰色 |

### 5. 插件扩展系统

- **标准化协议**：基于 `PeerPluginKit` 框架，支持第三方开发插件
- **动态加载**：插件可热加载，无需重启应用
- **独立运行**：每个插件拥有独立的 socket 通信和状态管理

### 6. 事件音效系统

- **可配置音效**：支持为不同事件配置不同的系统音效
- **事件类型**：Session 开始/结束、权限请求、任务完成、错误等
- **独立开关**：每种事件可单独启用/禁用音效

---

## 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                         meee2 App                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐   │
│  │ IslandView  │◄───│StatusManager │───►│ SessionMonitor  │   │
│  │  (SwiftUI)  │    │   (状态聚合)  │    │ (文件系统监控)   │   │
│  └─────────────┘    └──────┬───────┘    └─────────────────┘   │
│                            │                                    │
│                            ▼                                    │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   HookSocketServer                       │   │
│  │              (Unix Domain Socket 服务器)                  │   │
│  └─────────────────────────┬───────────────────────────────┘   │
│                            │                                    │
└────────────────────────────┼────────────────────────────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │       Claude CLI Hooks       │
              │   (/tmp/meee2.sock)     │
              └──────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        Plugin System                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ CursorPlugin │  │CopilotPlugin │  │  AimePlugin  │  ...     │
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

## 核心模块说明

### 1. HookSocketServer

Unix Domain Socket 服务器，监听 `/tmp/meee2.sock`，接收来自 Claude CLI hooks 的事件。

**支持的事件类型**：

| 事件 | 说明 | 是否需要响应 |
|------|------|-------------|
| `SessionStart` | 会话开始 | ❌ |
| `SessionEnd` | 会话结束 | ❌ |
| `PreToolUse` | 工具执行前 | ❌ |
| `PostToolUse` | 工具执行后 | ❌ |
| `PermissionRequest` | 权限请求 | ✅ Allow/Deny |
| `Notification` | 通知消息 | ❌ |
| `Stop` | 任务完成 | ❌ |
| `UserPromptSubmit` | 用户提交输入 | ❌ |

**权限响应流程**：

```swift
// 1. 接收 PermissionRequest 事件
event.expectsResponse == true  // event == .permissionRequest && status == "waiting_for_approval"

// 2. 保存 pending permission (保持 socket 连接)
pendingPermissions[toolUseId] = PendingPermission(clientSocket, event)

// 3. 用户点击 Allow/Deny
HookSocketServer.respondToPermissionBySession(sessionId, decision: "allow")

// 4. 发送 JSON 响应
{ "decision": "allow", "reason": null }

// 5. 关闭 socket 连接
```

### 2. SessionMonitor

文件系统监控服务，监听 `~/.claude/sessions/` 目录。

**工作流程**：

1. 监听目录文件变化 (DispatchSource)
2. 解析 JSON 文件获取 session 信息
3. 检查进程存活状态
4. 合并运行时状态（保留 hooks 更新的状态）

**Session 数据结构**：

```swift
struct AISession {
    let id: String          // Session UUID
    let pid: Int            // 进程 ID
    let cwd: String         // 工作目录
    let startedAt: Date     // 启动时间
    let type: SessionType   // claude/cursor/copilot/aime

    var status: SessionStatus  // running/completed/waiting/error
    var toolName: String?      // 当前工具名称
    var tty: String?           // 终端设备
    var termProgram: String?   // 终端程序名
}
```

### 3. StatusManager

状态聚合层，作为 UI 的数据源。

**职责**：

- 合并 `SessionMonitor` 和 `HookReceiver` 的数据
- 管理紧急会话列表 (`urgentSessions`)
- 处理权限审批操作
- 更新 UI 绑定的 `@Published` 属性

### 4. TerminalManager

智能终端跳转服务。

**跳转策略**（按优先级）：

1. **cmux**：通过 socket 路径和 surface ID 精确定位
2. **Ghostty/iTerm2**：使用 `TerminalJumper` 进行精确跳转
3. **通用终端**：通过 tty 设备和窗口标题匹配

### 5. PluginManager

插件生命周期管理。

**插件协议**：

```swift
protocol SessionPlugin {
    var pluginId: String { get }
    var config: PluginConfig { get }

    func initialize() -> Bool
    func start() -> Result<Void, Error>
    func stop()

    var onSessionsUpdated: (([PluginSession]) -> Void)? { get set }
    var onUrgentEvent: ((PluginSession, String, UrgentAction?) -> Void)? { get set }
}
```

---

## 安装与配置

### 1. 安装 Claude CLI Hooks

在 `~/.claude/settings.json` 中配置：

```json
{
  "hooks": {
    "SessionStart": [{
      "command": "/path/to/peer-island-bridge --source claude"
    }],
    "PermissionRequest": [{
      "command": "/path/to/peer-island-bridge --source claude"
    }],
    "Stop": [{
      "command": "/path/to/peer-island-bridge --source claude"
    }]
  }
}
```

### 2. 安装插件

将插件放置在 `~/.peer-island/plugins/` 目录：

```
~/.peer-island/plugins/
├── cursor-plugin/
│   ├── Package.swift
│   └── Sources/
├── copilot-plugin/
│   └── ...
```

---

## UI 设计

### 紧凑视图（Collapsed）

```
┌────────────────────────────────┐
│  ●  peer-island   Running...   │  ← 项目名 + 状态
└────────────────────────────────┘
```

### 展开视图（Expanded）

```
┌──────────────────────────────────────────┐
│  ●  peer-island  [Permission]  [Allow][Deny] │  ← Header + 按钮
├──────────────────────────────────────────┤
│                                          │
│  需要确认: Bash                          │  ← Message Box
│  tool_input:                             │
│    command: "rm -rf /tmp/test"          │
│                                          │
└──────────────────────────────────────────┘
```

---

## 技术栈

- **语言**：Swift 5.9
- **UI 框架**：SwiftUI
- **通信**：Unix Domain Socket
- **并发**：Swift Concurrency (async/await, Actor)
- **依赖管理**：Swift Package Manager

---

## 项目结构

```
peer/
├── App/                    # 应用入口
│   ├── meee2App.swift
│   └── AppDelegate.swift
├── Sources/
│   ├── Models/             # 数据模型
│   │   ├── AISession.swift
│   │   ├── SessionType.swift
│   │   └── HookEvent.swift
│   ├── Services/           # 核心服务
│   │   ├── HookSocketServer.swift
│   │   ├── SessionMonitor.swift
│   │   ├── StatusManager.swift
│   │   ├── TerminalManager.swift
│   │   └── PluginManager.swift
│   └── Views/              # SwiftUI 视图
│       ├── IslandView.swift
│       └── SettingsView.swift
└── Package.swift
```

---

## 后续规划

- [ ] 支持更多 AI 助手（Windsurf、Cline 等）
- [ ] 添加自定义主题配置
- [ ] 支持快捷键操作
- [ ] 添加历史记录查看
- [ ] 支持多显示器配置

---

## 相关链接

- **GitHub**: tianqixinxi/meee2
- **Claude CLI 文档**: https://docs.anthropic.com/claude-cli
- **Plugin 开发指南**: 见 `PeerPluginKit` 文档
# Plugin Development Guide

This guide explains how to create plugins for meee2.

## Overview

meee2 supports dynamic plugins that can be loaded from `~/.meee2/plugins/`. Each plugin is a Swift dynamic library (`.dylib`) that conforms to the `SessionPlugin` protocol defined in `Meee2PluginKit`.

## Plugin Structure

A plugin directory must contain:

```
~/.meee2/plugins/my-plugin/
├── plugin.json      # Plugin metadata (required)
├── MyPlugin.dylib   # Compiled dynamic library (required)
└── README.md        # Optional documentation
```

### plugin.json Schema

```json
{
  "id": "com.example.plugin.myplugin",  // Required: Unique identifier (reverse domain format)
  "name": "My Plugin",                   // Required: Display name
  "version": "1.0.0",                    // Required: Plugin version
  "dylib": "MyPlugin.dylib",            // Required: Dylib filename
  "icon": "star.fill",                   // Optional: SF Symbol icon name
  "color": "blue",                       // Optional: Theme color
  "minKitVersion": "1.0.0",             // Optional: Minimum Meee2PluginKit version
  "helpUrl": "https://example.com/help", // Optional: Help documentation URL
  "settings": [                          // Optional: Settings definitions
    {
      "key": "refreshInterval",
      "type": "slider",
      "min": 5,
      "max": 60,
      "default": 10,
      "label": "Refresh Interval (seconds)"
    }
  ]
}
```

## Creating a Plugin

### Step 1: Set Up Package.swift

Create a Swift package that depends on Meee2PluginKit:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyPlugin",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "MyPlugin",
            type: .dynamic,
            targets: ["MyPlugin"]
        ),
    ],
    dependencies: [
        // Meee2PluginKit is provided by meee2 at ~/.meee2/lib/libMeee2PluginKit.dylib
    ],
    targets: [
        .target(
            name: "MyPlugin",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("Meee2PluginKit"),
                .unsafeFlags(["-rpath", "@executable_path/../lib"], .when(platforms: [.macOS]))
            ]
        ),
    ]
)
```

### Step 2: Create the Plugin Class

```swift
import Foundation
import SwiftUI
import Meee2PluginKit

class MyPlugin: SessionPlugin {
    // MARK: - Identity

    override var pluginId: String { "com.example.plugin.myplugin" }
    override var displayName: String { "My Plugin" }
    override var icon: String { "star.fill" }
    override var themeColor: Color { .blue }
    override var version: String { "1.0.0" }
    override var helpUrl: String? { "https://example.com/help" }

    // MARK: - Lifecycle

    override func initialize() -> Bool {
        // Load configuration, set up resources
        return true
    }

    override func start() -> Bool {
        // Start monitoring, timers, file watchers
        return true
    }

    override func stop() {
        // Stop timers, cleanup
    }

    // MARK: - Session Management

    override func getSessions() -> [PluginSession] {
        // Return current sessions
        return []
    }

    override func refresh() {
        // Refresh session data and notify
        let sessions = getSessions()
        onSessionsUpdated?(sessions)
    }

    // MARK: - Terminal Activation

    override func activateTerminal(for session: PluginSession) {
        // Open the terminal/app for this session
    }
}
```

### Step 3: Create the Export Function

Create a separate file (e.g., `MyPluginExport.swift`) with the C-exported factory function:

```swift
import Foundation
import Meee2PluginKit

@_cdecl("createPlugin")
public func createPlugin() -> UnsafeMutableRawPointer {
    let plugin = MyPlugin()
    return Unmanaged.passRetained(plugin).toOpaque()
}
```

### Step 4: Build

Build the plugin as a dynamic library:

```bash
# Ensure Meee2PluginKit.dylib is available
export MEEE2_PLUGIN_KIT_PATH=~/.meee2/lib/libMeee2PluginKit.dylib

# Build
swift build -c release

# Copy to plugins directory
cp .build/release/MyPlugin.dylib ~/.meee2/plugins/my-plugin/
```

## PluginSession Model

The `PluginSession` struct represents a session in the UI:

```swift
public struct PluginSession {
    // Required
    let id: String              // Unique ID (e.g., "pluginId-sessionId")
    let pluginId: String        // Your plugin ID
    let title: String           // Display title (project name, file name)
    var status: SessionStatus   // Current status
    let startedAt: Date         // When session started

    // Optional
    var subtitle: String?       // Subtitle (task description)
    var lastUpdated: Date?      // Last update time
    var progress: Int?          // Progress percentage (0-100)
    var errorMessage: String?   // Error message if failed
    var toolName: String?       // Current tool name
    var cwd: String?            // Working directory
    var terminalInfo: PluginTerminalInfo? // Terminal jump info

    // UI customization
    var icon: String?           // SF Symbol override
    var accentColor: Color?     // Color override

    // Urgent events (requires user attention)
    var urgentEvent: UrgentEventInfo?

    // Enhanced fields (optional)
    var detailedStatus: DetailedStatus? // Fine-grained status
    var tasks: [SessionTask]?            // Task tracking
    var usageStats: UsageStats?          // Token/cost stats
}
```

### SessionStatus Values

```swift
enum SessionStatus {
    case idle       // Not active
    case running    // Actively processing
    case thinking   // Processing user input
    case tooling    // Executing tool
    case waitingInput // Waiting for user input
    case permissionRequest // Needs permission
    case completed  // Finished successfully
    case failed     // Failed with error
    case compacting // Compacting context
}
```

### DetailedStatus Values

```swift
enum DetailedStatus {
    case idle              // 💤 Idle
    case thinking          // 🤔 Thinking
    case tooling           // 🔧 Tooling
    case active            // ⚡ Active
    case waitingForUser    // ⏳ Waiting
    case permissionRequired // 🔐 Permission
    case compacting        // 📦 Compacting
    case completed         // ✅ Completed
    case dead              // 💀 Dead
}
```

## Terminal Jump

To enable terminal jump functionality, provide `PluginTerminalInfo`:

```swift
session.terminalInfo = PluginTerminalInfo(
    tty: "/dev/ttys001",           // TTY device
    termProgram: "Ghostty",        // Terminal app name
    termBundleId: "com.mitchellh.ghostty", // Bundle ID
    cmuxSocketPath: "...",         // cmux socket (if using)
    cmuxSurfaceId: "..."           // cmux surface ID
)
```

## Urgent Events

For events requiring user attention (like permission requests):

```swift
session.urgentEvent = UrgentEventInfo(
    id: "permission-123",
    eventType: "permission",
    message: "Allow Bash command execution?",
    actionLabel: "Approve",
    respond: { decision in
        switch decision {
        case .allow:
            // Approve the action
        case .deny(reason):
            // Deny with optional reason
        }
    }
)
```

## Version Compatibility

### ABI Stability

Swift dynamic libraries are **not ABI stable**. If the `Meee2PluginKit` interface changes, old plugins may fail to load with "Symbol not found" errors.

To maintain compatibility:

1. **Always rebuild plugins** when meee2 is updated
2. **Specify `minKitVersion`** in plugin.json for early failure detection
3. **Use backward-compatible initializers** (meee2 provides these for PluginSession)

### minKitVersion

Add to your plugin.json:

```json
{
  "minKitVersion": "1.0.0"
}
```

This helps meee2 detect incompatible plugins early and show appropriate error messages.

## Logging

Use `PluginLog()` for logging:

```swift
PluginLog("[MyPlugin] Started monitoring")
```

Logs are written to the meee2 log file and system logs.

## Example: CursorPlugin

See `plugins-builtin/Sources/Plugins/Builtin/CursorPlugin.swift` for a complete example.

## Testing

1. Copy your plugin to `~/.meee2/plugins/my-plugin/`
2. Restart meee2
3. Check logs for loading status
4. Verify sessions appear in the UI

## Troubleshooting

### Symbol not found

**Cause**: Plugin compiled against old Meee2PluginKit version.

**Solution**: Rebuild plugin against current Meee2PluginKit.

### Duplicate class warnings

**Cause**: Two copies of Meee2PluginKit loaded.

**Solution**: Ensure plugin links against `~/.meee2/lib/libMeee2PluginKit.dylib` (preloaded by meee2).

### Plugin not showing

**Cause**: `plugin.json` missing or malformed.

**Solution**: Verify plugin.json exists and has required fields.

## Resources

- [Meee2PluginKit Source](../meee2-plugin-kit/Sources/Meee2PluginKit/)
- [CursorPlugin Example](../plugins-builtin/Sources/Plugins/Builtin/CursorPlugin.swift)
- [SessionPlugin.swift](../meee2-plugin-kit/Sources/Meee2PluginKit/SessionPlugin.swift)
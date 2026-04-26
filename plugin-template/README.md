# meee2 Plugin Template

A template for creating custom plugins for [meee2](https://github.com/tianqixinxi/meee2).

## Quick Reference

| Step | Action | Command |
|------|--------|---------|
| 1 | Copy template | `cp -r plugin-template ~/my-plugin` |
| 2 | Replace placeholders | See below |
| 3 | Build | `swift build -c release` |
| 4 | Install | Copy `.dylib` to `~/.meee2/plugins/` |

## Plugin Structure

```
~/my-plugin/
├── Package.swift           # Package config (links to Meee2PluginKit)
├── Sources/
│   ├── {{PLUGIN_NAME}}.swift       # Main plugin class
│   └── {{PLUGIN_NAME}}Export.swift # C export function
```

## Required Properties

Every plugin must override these properties:

| Property | Type | Example | Description |
|----------|------|---------|-------------|
| `pluginId` | String | `"com.meee2.plugin.my-plugin"` | Unique ID (reverse domain) |
| `displayName` | String | `"My Plugin"` | Human-readable name |
| `icon` | String | `"star.fill"` | SF Symbol icon name |
| `themeColor` | Color | `.purple` | SwiftUI Color |
| `version` | String | `"1.0.0"` | Plugin version |

## Required Methods

| Method | When Called | What to Do |
|--------|-------------|------------|
| `initialize()` | Plugin load | Setup resources, return `true` if success |
| `start()` | Plugin enabled | Start timers, file watchers |
| `stop()` | Plugin disabled | Stop timers, cleanup |
| `getSessions()` | UI refresh | Return current `PluginSession` array |
| `refresh()` | Timer interval | Update sessions, call `onSessionsUpdated?()` |
| `activateTerminal(for:)` | User clicks row | Open terminal/app for session |

## Callbacks

| Callback | Signature | When to Call |
|----------|-----------|--------------|
| `onSessionsUpdated` | `([PluginSession]) -> Void` | Sessions change |
| `onUrgentEvent` | `(PluginSession, String, String?) -> Void` | Permission request, important notification |

## Minimal Plugin Example

```swift
import Foundation
import SwiftUI
import Meee2PluginKit

class MyPlugin: SessionPlugin {
    // Identity (required)
    override var pluginId: String { "com.meee2.plugin.my-plugin" }
    override var displayName: String { "My Plugin" }
    override var icon: String { "star.fill" }
    override var themeColor: Color { .purple }
    override var version: String { "1.0.0" }

    private var timer: Timer?

    // Lifecycle
    override func initialize() -> Bool { return true }
    override func start() -> Bool {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            self.refresh()
        }
        return true
    }
    override func stop() { timer?.invalidate(); timer = nil }

    // Sessions
    override func getSessions() -> [PluginSession] {
        // Scan your data source and return sessions
        return []
    }

    override func refresh() {
        let sessions = getSessions()
        onSessionsUpdated?(sessions)  // Notify UI
    }

    // Terminal jump
    override func activateTerminal(for session: PluginSession) {
        // Open terminal at session.cwd
    }
}
```

## Export Function (Required)

Create `MyPluginExport.swift`:

```swift
import Meee2PluginKit

@_cdecl("createPlugin")
public func createPlugin() -> UnsafeMutableRawPointer {
    let plugin = MyPlugin()
    return Unmanaged.passRetained(plugin).toOpaque()
}
```

## SessionStatus Values

| Status | Color | Meaning |
|--------|-------|---------|
| `.running` | Blue | Active processing |
| `.idle` | Gray | Not active |
| `.waitingForUser` | Orange | Needs user input |
| `.error` | Red | Failed with error |

## DetailedStatus (Optional)

For fine-grained status display:

| Status | Icon | Color | Use Case |
|--------|------|-------|----------|
| `thinking` | 🤔 | Blue | Processing input |
| `tooling` | 🔧 | Blue | Executing tool |
| `waitingForUser` | ⏳ | Orange | Needs intervention |
| `permissionRequired` | 🔐 | Orange | Permission request |
| `compacting` | 📦 | Blue | Context compression |
| `completed` | ✅ | Gray | Finished |
| `dead` | 💀 | Red | Abnormal termination |
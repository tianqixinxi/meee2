import Meee2PluginKit
import SwiftUI

/// {{PLUGIN_NAME}} - A custom plugin for meee2
///
/// This is a template plugin. Replace {{PLUGIN_NAME}} with your plugin name
/// and implement the SessionPlugin protocol.
public class {{PLUGIN_NAME}}Plugin: SessionPlugin {

    // MARK: - SessionPlugin Properties

    public override var pluginId: String { "{{PLUGIN_ID}}" }
    public override var displayName: String { "{{DISPLAY_NAME}}" }
    public override var icon: String { "puzzlepiece.extension" }
    public override var themeColor: Color { .blue }
    public override var version: String { "0.1.0" }
    public override var helpUrl: String? { nil }

    // MARK: - Lifecycle

    public override func initialize() -> Bool {
        // Perform initialization here
        // Return false to indicate initialization failure
        return true
    }

    public override func start() -> Bool {
        // Start your plugin logic here
        return true
    }

    public override func stop() {
        // Clean up when plugin is stopped
    }

    public override func cleanup() {
        // Final cleanup when plugin is unloaded
    }

    // MARK: - Sessions

    public override func getSessions() -> [PluginSession] {
        // Return a list of sessions your plugin manages
        // Example:
        // return [
        //     PluginSession(
        //         id: "session-1",
        //         title: "My Session",
        //         status: .idle,
        //         pluginId: pluginId
        //     )
        // ]
        return []
    }

    public override func refresh() {
        // Refresh session data
        let sessions = getSessions()
        onSessionsUpdated?(sessions)
    }

    public override func activateTerminal(for session: PluginSession) {
        // Called when user clicks on a session row
        // Launch or focus the terminal for the given session
    }
}

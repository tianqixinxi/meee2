# Sessions Workspace and Terminal Overlay are hybrid surfaces

Supersedes [0004-session-terminal-overlay-replaces-sessions-workspace](0004-session-terminal-overlay-replaces-sessions-workspace.md).

meee2 uses two terminal surfaces because session work has two different user intents. Session Terminal Overlay is the Canvas-scoped way to inspect or act on one meee2-managed terminal without leaving the current Canvas context. Sessions Workspace is the global workspace for browsing, searching, switching, and operating across local sessions.

The default route is contextual split. Canvas, node, and monitor interactions open Session Terminal Overlay. Global commands, menu actions, Quick Open session navigation, and launcher recovery open Sessions Workspace.

The trade-off is that both surfaces must share one native terminal lifecycle. A meee2-managed terminal process and Ghostty surface belong to the terminal backend, not to either host. Switching between Sessions Workspace and Session Terminal Overlay should attach, focus, lay out, hide, or release the same live surface; host cache eviction must not detach or end the terminal session.

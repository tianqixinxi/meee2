# Session Terminal Overlay Replaces Sessions Workspace

Superseded by [0012-sessions-workspace-and-terminal-overlay-are-hybrid-surfaces](0012-sessions-workspace-and-terminal-overlay-are-hybrid-surfaces.md).

Canvas Workspace is the organizing surface for live sessions, nodes, subcanvases, recap, and evidence. Opening a meee2-managed local session should keep the user in that Canvas context, so the Web Board no longer exposes a top-level Sessions workspace. Instead, session search remains in Quick Open, Monitor continues to surface live-session status, and a Session Terminal Overlay opens the selected native terminal in a Canvas-scoped modal.

The trade-off is that session controls must live in contextual Canvas surfaces rather than in one global session page. This keeps the terminal modal focused on the session body, preserves the Canvas mental model, and prevents the old Sessions page from becoming a second operating workspace beside Monitor Canvas. The modal chrome stays intentionally sparse: title, state, terminal viewport, and an explicit close button.

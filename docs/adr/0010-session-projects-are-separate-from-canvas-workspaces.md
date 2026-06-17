# Session Projects are separate from Canvas Workspaces

Session Project is a local folder-backed launch context for Codex and Claude sessions, while Canvas Workspace is the visual and workflow organization model for meee2. We keep them separate so a user can open `~/Code/foo` and start a native terminal session without implicitly creating or switching a Canvas, while still allowing those sessions to be attached to canvases later when workflow organization is useful.

Session Projects are explicit: a folder becomes a Session Project only when the user adds it. Historical session `cwd` values no longer create inferred projects in the launcher, because that blurs the boundary between durable projects and temporary work.

Temporary sessions use meee2-created Temporary Session Workspaces under `~/.meee2/workspaces/temporary/`. Those directories are valid local session working directories, but they are not Session Projects and should appear under the launcher’s temporary conversation group unless the user later starts a separate explicit project flow.

# meee2

meee2 is a local AI session workspace for people running Claude Code, Codex, and similar tools. This context names the product concepts used to discuss how local sessions are connected, organized, controlled, and reviewed.

## Language

**Local Session Readiness**:
The state where meee2 can receive real local AI session activity, show the workspace surface, persist local state, and give the user a concrete recovery action when an essential connection fails.
_Avoid_: Agent Runtime setup, because that only names one part of the readiness chain.

**Readiness Check**:
A local setup check made of required and optional items. Local Session Readiness requires at least one supported local provider runtime to be installed and configured, plus every essential meee2 surface to be ready; other absent providers may be recommended without blocking readiness.
_Avoid_: Health score, setup percentage

**Supported Provider**:
A local AI tool integration that meee2 knows how to connect to for session activity. M0 requires one Supported Provider to be ready; additional providers can be configured later unless the user chooses that provider for setup.
_Avoid_: Optional integration, best-effort provider

**Degraded Entry**:
The user may enter the workspace while Local Session Readiness is incomplete, but meee2 must continue to present the unresolved readiness failures as active setup work. Degraded Entry is not the same as completing onboarding.
_Avoid_: Skip as ready, setup complete

**Recovery Action**:
The primary user action attached to a failed Readiness Check item. A Recovery Action either fixes the item automatically or takes the user to the exact place needed to fix it.
_Avoid_: Log-only diagnosis, vague troubleshooting

**Provider Hook**:
The provider-side event connection that lets meee2 receive local session activity from a Supported Provider. Provider Hook readiness is checked separately from provider runtime installation.
_Avoid_: Hidden plugin detail, runtime installed

**Synthetic Probe**:
A meee2-generated local event used to prove that the session ingestion path can receive and process input without requiring the user to start a real provider session. A Synthetic Probe does not prove that a Supported Provider will emit real events correctly.
_Avoid_: Real session test, provider verification

**Local State Store**:
The local storage used by meee2 for session records, board layout, and runtime setup state. M0 readiness requires the essential Local State Store paths to be creatable, readable, and writable.
_Avoid_: All local files, artifact storage

**Readiness Surface**:
The product surface where users inspect Readiness Checks and run Recovery Actions. M0 uses the Web Board and Settings as Readiness Surfaces; the Island is not a Readiness Surface.
_Avoid_: Island setup flow, menu bar checklist

**Web Board**:
The React-based main workspace surface inside the meee2 app, covering Canvas, Monitor, Settings, Artifacts, Templates, Team, and Integrations. Web Board notification design is separate from native macOS attention surfaces.
_Avoid_: Native overlay, Dynamic Island, system notification

**Web Board Theme Profile**:
A local appearance preference that changes how the Web Board presents color and contrast on one Mac, including the Board sidebar surface color. A Web Board Theme Profile does not define Canvas rendering semantics, plugin identity colors, team-shared settings, or Native Attention Surface styling.
_Avoid_: Canvas Render Profile, plugin theme, team design system, Dynamic Island theme

**Native Attention Surface**:
A macOS-level meee2 surface such as Dynamic Island, menu bar overlay, NSAlert, or system notification. Native Attention Surfaces are reserved for cross-window or urgent attention and are not the default home for Web Board UI feedback.
_Avoid_: Web toast, canvas banner, inline form error

**Toast**:
A temporary Web Board message for non-blocking operation feedback that can disappear without changing the user's next action. Toast must not carry setup work, recovery tasks, or state that the user needs later.
_Avoid_: Persistent warning, setup task, inline error, action backlog

**Notice**:
A persistent, non-blocking Web Board message anchored to the surface where the user can understand or act on it. Banners, inline errors, auth prompts, and local warning panels are Notice layouts rather than separate notification concepts.
_Avoid_: Toast, modal, floating alert taxonomy

**Dialog**:
A blocking Web Board interaction used when the user must explicitly confirm, repair, or choose before the action continues.
_Avoid_: Banner, toast, passive warning

**Web Board Layer Order**:
The fixed stacking relationship for Web Board feedback and overlays: Dialog appears above Toast, Toast appears above protected Inspector overlays, Inspector overlays appear above Notice, and Notice appears above ordinary content only when its surface requires an overlay layout.
_Avoid_: Component-local z-index ladders, toast above dialog

**Doctor**:
The command-line view of the same Readiness Checks shown in the Web Board and Settings. Doctor is an auxiliary diagnostics path, not the primary M0 onboarding path.
_Avoid_: Separate health-check logic, shell-only setup

**Readiness Severity**:
The readiness impact of a check item: required items block Local Session Readiness, recommended items suggest useful setup, and informational items only explain current state. A Supported Provider installed on the machine makes its provider-specific readiness items required.
_Avoid_: Flat warning list, percentage score

**Onboarding Completion**:
The state recorded only after all required Readiness Checks pass and the user continues into the workspace. Entering through Degraded Entry or dismissing setup UI does not create Onboarding Completion.
_Avoid_: Skip as completion, banner dismissed as ready

**Empty Session State**:
The workspace state before meee2 has seen the user's first real provider session. M0 should explain that meee2 is waiting for a real session rather than substituting a demo session.
_Avoid_: Demo mode, fake session as readiness

**Canonical Session Identity**:
The provider-native session identity paired with its Supported Provider. meee2 may expose prefixed or routed ids in UI and APIs, but persistence, deduplication, and recovery should resolve back to Canonical Session Identity.
_Avoid_: UI id as truth, plugin-prefixed id as recovery key

**Session Observation**:
One sighting of a Canonical Session Identity from a provider hook, transcript, process scan, local store, terminal surface, or plugin state. A Session Observation is evidence about a session, not a separate session by itself.
_Avoid_: New session per source, duplicate source card

**Session Continuity**:
The guarantee that user-owned session state remains attached to the same Canonical Session Identity while runtime details such as PID, terminal id, transcript path, and status may change or disappear.
_Avoid_: Delete and recreate on restart, process lifetime as session lifetime

**Session Merge**:
The process of combining multiple Session Observations for the same Canonical Session Identity into one meee2 session. Session Merge preserves user-owned state and chooses authoritative sources per field instead of letting one source replace the whole session.
_Avoid_: Last writer wins session, duplicate session card

**Needs Rebind**:
A session state where meee2 cannot safely reconnect stored local state to a current provider session without user confirmation. Unambiguous id normalization or recovery may happen automatically; changing the ownership of work across sessions must not happen silently.
_Avoid_: Silent migration, automatic reassignment

**Session Intake Diagnostic**:
A user-visible explanation of why a real provider session is missing, duplicated, stale, or waiting for rebind. Session Intake Diagnostic belongs after onboarding because it diagnoses real session continuity, not local setup readiness.
_Avoid_: Generic empty state, silent recovery failure

**Live Session Surface**:
A default monitoring surface that shows sessions still relevant to current work. Completed and dead sessions remain stored for Session Continuity but leave Live Session Surfaces unless they still carry an unresolved user-action signal.
_Avoid_: History list as monitor, delete-to-hide

**Session Terminal Overlay**:
A Canvas-scoped modal that opens one meee2-managed local session terminal in place. A Session Terminal Overlay is not a global session list, not a separate workspace mode, and not the home for session search or bulk session controls.
_Avoid_: Sessions page, terminal workspace, session list modal

**Session Project**:
A user-selected local folder used as the working directory and grouping context for starting or reopening local AI sessions. A Session Project is not a Canvas Workspace; it names where the agent runs, not where meee2 organizes visual workflow state.
_Avoid_: Canvas, generated workspace folder, project card as session identity

**Session Project Display Name**:
A user-editable launcher label for a Session Project. Changing the Session Project Display Name does not rename, move, or reassign the underlying local folder path.
_Avoid_: Folder rename, project path migration, session identity rename

**Session Project Launcher**:
The default Web Board surface for choosing a Session Project, selecting a Supported Provider, and starting or reopening a meee2-managed local session. It creates sessions in native terminal surfaces without automatically binding them to a Canvas Workspace.
_Avoid_: Progress page, Canvas launcher, Session Terminal Overlay

**Temporary Session Workspace**:
A meee2-created local working directory for a temporary local session that is not saved as a Session Project. Temporary Session Workspaces let the user start recoverable local sessions without registering a project folder.
_Avoid_: Inferred project, scratch Canvas, unsaved Session Project

**Pinned Session**:
A user-level launcher preference that lifts a session into the Session Project Launcher's global pinned group without changing Canonical Session Identity, session continuity, or project membership.
_Avoid_: Project pin, backend ownership change, duplicate session

**Canvas Workspace**:
A user-owned container that organizes live sessions, workflow nodes, subcanvases, recap, and Artifacts. A Canvas Workspace may be shown as a monitor, board, or workflow, but it remains the same organizing concept.
_Avoid_: Graph editor as the product, separate monitor workspace

**Template Canvas**:
A Canvas Workspace that is published or reusable as a starting point for new canvases. A Template Canvas is still a canvas, not a separate canvas kind.
_Avoid_: Template kind, template-only workspace

**Canvas Render Protocol**:
The shared language for deriving what appears on a canvas from canvas content, render rules, and user-editable render values. It lets workflow graphs, monitors, scene canvases, and artifact boards share one canvas model.
_Avoid_: Graph-only canvas, scene-specific bypass

**Canvas Render Profile**:
The canvas-owned description of how a Canvas Workspace should be presented. A Canvas Render Profile combines Render Logic with Render Values.
_Avoid_: Node layout as truth, hidden renderer state

**Canvas Event Log**:
The append-oriented record of what changed on a Canvas Workspace. Canvas Event Log history supports activity timelines, recaps, and debugging, but it is not the current canvas snapshot and should not define presentation.
_Avoid_: Current state, render profile, artifact truth

**Canvas Object**:
An item that can be rendered on a canvas, either backed by a real entity such as a node, Artifact, session, or subcanvas, or render-only such as a label, region, asset, or background.
_Avoid_: Fake node, visual-only workflow node

**Canvas Relation**:
A renderable relationship between Canvas Objects, such as dependency, dataflow, membership, projection, spatial link, or grouping.
_Avoid_: Edge as only dependency, implicit visual link

**Render Logic**:
The declarative rules that say which Canvas Objects and Canvas Relations exist and which built-in renderers, layouts, and actions present them.
_Avoid_: User React code, arbitrary CSS, plugin renderer

**Render Values**:
The user-editable presentation values for a canvas, such as position, size, visibility, collapsed state, pinning, and renderer variant.
_Avoid_: Workflow status, Artifact truth, execution state

**Canvas Scene**:
A canvas-level presentation surface for spatial or simulated experiences such as a travel map or poker table. A Canvas Scene is not a node, because it does not own work; it presents Scene State and routes user intent to executable nodes.
_Avoid_: Scene Host Node, game page, map node

**Template Asset**:
A reusable presentation resource that comes with a Canvas Workspace template and may be overridden by the canvas. Template Assets are not Artifacts because they are not evidence produced by work.
_Avoid_: seed artifact, evidence asset

**Scene State**:
The structured state rendered by a Canvas Scene. Initial Scene State may come from a template, while running Scene State is advanced by Artifacts produced by nodes.
_Avoid_: canvas artifact, hidden bootstrap output

**Rules Orchestrator**:
A deterministic canvas-runtime controller for simulated Canvas Scenes. A Rules Orchestrator decides what may happen next and which role may act, but it is not a node, not an AI session, and not a scene character such as Dealer or GM.
_Avoid_: GM as orchestrator, Dealer as orchestrator, hidden orchestration node

**Role Slice**:
The subset of Scene State visible to a specific human or AI role. A Role Slice lets a player session see its own private inputs while hiding other roles' private information.
_Avoid_: full scene state as player context, hidden information leak

**Player Action Artifact**:
A node-produced Artifact that records one player role's proposed action for the current scene turn. A Player Action Artifact is not the authoritative Scene State; the Rules Orchestrator must validate and apply it before Scene State advances.
_Avoid_: player-owned game state, direct scene mutation

**Dealer / Table State**:
The Poker Table state owner used to keep authoritative `game-state.json` and `action-log.json` node-scoped. It is rendered as a system table-state control, not as a player seat and not as an AI session node.
_Avoid_: AI Dealer as flow controller, Dealer player node

**Monitor Canvas**:
The default Canvas Workspace that aggregates active live sessions, subcanvases, blocked work, approvals, recap, and Artifacts into a top-level operating view.
_Avoid_: Separate Monitor product, history dashboard

**Subcanvas Node**:
A node in one Canvas Workspace that represents another Canvas Workspace and surfaces that child workspace's aggregate state.
_Avoid_: Link-only shortcut, nested graph detail

**Aggregated Node State**:
The explainable state of a node derived from its bound live session, workflow state, subcanvas state, approvals, blockers, and Artifacts rather than only from manual status.
_Avoid_: Manual status as truth, done-only workflow state

**Artifact**:
Traceable work proof attached to a Canvas Workspace or node, such as file diffs, command results, tool calls, documents, screenshots, pull requests, and node outputs.
_Avoid_: Canvas Evidence, status without proof, hidden artifact

**Artifact Candidate**:
Session-attached traceable work proof captured from agent hooks before it is archived into a Canvas Workspace or node. Artifact Candidates are globally searchable evidence, but they are not canonical node outputs until promoted into an Artifact.
_Avoid_: Draft Artifact, hidden hook output, automatic node output

**Provider Recap Signal**:
A provider-native summary signal observed from a Supported Provider, such as Claude Code `away_summary` / `/recap` or a Codex compact summary. A Provider Recap Signal is source material for a Session Recap, not the normalized recap itself; provider adapters expose signals, while recap-core owns cross-provider normalization.
Claude human-facing summaries and Codex context-compaction summaries are different Provider Recap Signal intents, and context-compaction signals must not automatically become Display Session Titles.
_Avoid_: Session Recap, canonical summary, display title, all provider summaries as equal

**Session Recap**:
A normalized cross-provider recap projection for one Canonical Session Identity. Session Recap may be built from Provider Recap Signals, transcript tails, user notes, and artifacts, but meee2 owns its source, evidence, freshness, and display suitability.
_Avoid_: Provider raw summary, Claude recap, Codex compact summary

**Display Session Title**:
A user-facing label deterministically derived for compact session surfaces from user rename overrides, Session Recap, active task, prompt text, provider title, or folder context. A Display Session Title is not Canonical Session Identity, must not rename or reassign the underlying session, and does not require an LLM in the default path.
_Avoid_: Session identity, provider title as truth, recap as title

**Artifact View**:
A named projection over an Artifact's data, owned by the Artifact and carried with it wherever the Artifact is shown. Canvas cards, Inspector detail, and the Artifacts rail choose and render Artifact Views, but do not own the view definitions.
_Avoid_: Canvas Render Value, widget-local tab, duplicate artifact data

## Example Dialogue

Developer: "Is M0 done if the agent runtime is installed?"

Domain expert: "Not by itself. M0 means Local Session Readiness: the user can connect Claude Code, see that meee2 is alive, and knows exactly what to fix if the local session chain is broken."

Developer: "What if Codex is installed but not configured?"

Domain expert: "Then M0 is not ready. Installed Supported Providers must be configured, while providers not present on the machine do not block readiness."

Developer: "Can the user skip setup and still open the workspace?"

Domain expert: "Yes, that is Degraded Entry. The workspace opens, but readiness failures stay visible until they are fixed."

Developer: "Is an error paragraph enough for a failed setup item?"

Domain expert: "No. Every failed required Readiness Check needs a Recovery Action."

Developer: "If the Claude plugin is installed, can we assume sessions will appear?"

Domain expert: "No. The Provider Hook is a separate required readiness item, because runtime installation and event delivery can fail independently."

Developer: "Does M0 require the user to start a real Claude Code session?"

Domain expert: "No. M0 uses a Synthetic Probe for the local ingestion path, then waits for the first real provider session after entry."

Developer: "Do artifacts and debug exports have to pass storage checks before onboarding can complete?"

Domain expert: "No. M0 checks the essential Local State Store paths for sessions, board layout, and runtime setup state."

Developer: "Should the Island show setup status?"

Domain expert: "No. Readiness belongs in the Web Board and Settings, not in the Island."

Developer: "Should CLI diagnostics have its own definition of healthy?"

Domain expert: "No. Doctor reports the same Readiness Checks as the Web Board and Settings."

Developer: "Does a missing optional provider make setup fail?"

Domain expert: "No. Missing providers are informational or recommended, but an installed Supported Provider upgrades its readiness checks to required."

Developer: "Can Skip for now mark onboarding complete?"

Domain expert: "No. Only passing required checks can create Onboarding Completion."

Developer: "Should M0 show demo sessions when no real sessions exist?"

Domain expert: "No. Empty Session State should wait for and guide the first real provider session."

Developer: "Are `com.meee2.plugin.claude-abc` and Claude session `abc` different sessions?"

Domain expert: "No. The provider-native id is the Canonical Session Identity; prefixed ids are presentation or routing details."

Developer: "If transcript discovery and a hook event both describe the same session, which one wins?"

Domain expert: "Neither wins wholesale. Session Merge uses the canonical identity and picks the best source for each field while preserving user-owned state."

Developer: "Can meee2 automatically attach old work to a newly launched session?"

Domain expert: "Only when the relationship is unambiguous. Otherwise the session is Needs Rebind and the user confirms the new binding."

Developer: "If a Claude process exits, should meee2 delete the stored session?"

Domain expert: "No. Process exit is a Session Observation about runtime state, not proof that the work stopped existing. Session Continuity keeps the record and marks the runtime as ended or recoverable."

Developer: "If PID scan, hook events, and transcript discovery all report the same provider-native id, do we show three cards?"

Domain expert: "No. Those are Session Observations for one Canonical Session Identity and must merge into one session."

Developer: "If a stored id no longer opens but transcript or provider metadata gives an unambiguous current id, can meee2 repair it?"

Domain expert: "Yes. Reliable Session Intake can automatically recover unambiguous stale ids while preserving user-owned state; ambiguous cases become Needs Rebind."

Developer: "If we preserve dead and completed sessions, should the main monitor show all of them?"

Domain expert: "No. The main monitor is a Live Session Surface. Historical records are still available to diagnostics and history, but they do not pollute the default live view."

Developer: "Should Monitor and Canvas be two rail entries?"

Domain expert: "No. Monitor is the default Monitor Canvas inside the Canvas Workspace model; users can drill from it into sessions, nodes, artifacts, and subcanvases without learning a separate product surface."

Developer: "Can a node be marked done just because the workflow says done?"

Domain expert: "Not always. Aggregated Node State must explain which Artifact or child state produced it, and live-session or monitor templates are not forced into a done-only lifecycle."

Developer: "Should Artifacts be their own workspace for managing generated material?"

Domain expert: "No. Artifacts are traceable work proof attached to Canvas Workspaces or nodes. The Artifacts rail entry is a global index for finding them, while editing and workflow decisions stay in Canvas."

Developer: "Should a poker table or travel map be represented as one giant node?"

Domain expert: "No. That is a Canvas Scene: the table or map presents Scene State at the canvas level. Player agents, route planner, hotel agent, or human approvals become nodes because they own executable work. Poker Dealer / Table State is only the node-scoped home for system-written state artifacts."

Developer: "If the poker felt or travel background ships with a template, is that an Artifact?"

Domain expert: "No. It is a Template Asset. Artifacts are proof produced by nodes; Template Assets are reusable presentation resources."

Developer: "Is the GM node the thing that controls a poker game?"

Domain expert: "No. The GM is a human responsibility node for rulings and approvals. The Rules Orchestrator is the deterministic runtime controller, and player agents only submit Player Action Artifacts."

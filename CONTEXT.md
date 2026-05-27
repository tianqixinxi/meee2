# meee2

meee2 is a local AI session workspace for people running Claude Code, Codex, and similar tools. This context names the product concepts used to discuss how local sessions are connected, organized, controlled, and reviewed.

## Language

**Local Session Readiness**:
The state where meee2 can receive real local AI session activity, show the workspace surface, persist local state, and give the user a concrete recovery action when an essential connection fails.
_Avoid_: Agent Runtime setup, because that only names one part of the readiness chain.

**Readiness Check**:
A local setup check made of required and optional items. Local Session Readiness requires every installed supported provider and every essential meee2 surface to be ready; unsupported or absent providers may be shown without blocking readiness.
_Avoid_: Health score, setup percentage

**Supported Provider**:
A local AI tool integration that meee2 knows how to connect to for session activity. If a Supported Provider is installed on the user's machine, M0 treats it as required for Local Session Readiness.
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

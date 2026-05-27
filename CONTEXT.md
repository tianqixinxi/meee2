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

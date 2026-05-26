# Recap Core Contract

Status: draft for review. Initial `packages/recap-core` scaffold exists.

This document defines the cross-platform recap contract for the release-track
recap upgrade. Recap must not live in the Swift/macOS runtime. Swift can expose
local session, transcript, artifact, and planner state, but recap semantics,
aggregation, prompts, caching, and AI-output parsing belong in a portable
TypeScript domain layer.

## Product Rules

- Recap is workspace intelligence, not a macOS-only feature.
- A recap explains what happened, what is blocked, what needs approval, what was
  produced, and where the evidence is.
- Session recap and canvas recap share one model, but can have different sources.
- Deterministic recap is always available. AI recap can improve wording, but
  must never be the only source of truth.
- Recap output must be cacheable by input fingerprint so switching canvases does
  not regenerate repeatedly.
- Recap must carry evidence references. A "done" or "blocked" claim without a
  source is low trust.
- Provider-specific transcript parsing is an adapter detail. Canvas aggregation
  must stay provider-agnostic.
- Template-specific recap strategy is allowed, but the default strategy must work
  for monitor, workflow, inbox/list, owner matrix, dependency graph, and kanban
  canvases.

## Non-goals

- No Swift-only recap service.
- No long-term memory system in this contract.
- No team realtime sync protocol in this contract.
- No requirement that every recap is AI generated.
- No requirement to fully parse every transcript format before the first cut.

## Package Boundary

Preferred package layout:

```text
packages/recap-core/
  src/types.ts
  src/session.ts
  src/canvas.ts
  src/fingerprint.ts
  src/prompt.ts
  src/parse.ts
  src/cache.ts
  src/index.ts
```

If adding a package is too much for the first spike, these files may start under
`packages/board-core/src/recap/` with the same public API. The API should remain
framework-free: no React, DOM, localStorage, fetch, Swift DTO imports, or app
singletons.

App/runtime adapters live outside recap-core:

| Layer | Responsibility |
|---|---|
| `recap-core` | Types, deterministic aggregation, fingerprints, prompt building, AI response parsing. |
| `board-app` | React hooks, refresh UX, timed refresh, rendering, user preferences. |
| `board-persistence-http` or app adapter | Load/save recap cache through HTTP, IndexedDB, localStorage, or cloud storage. |
| Swift `BoardServer` | Expose source data only: board state, planner graph, transcript tails, artifacts, sessions. |
| Cloud/online service | May reuse recap-core with different adapters and model providers. |

## Data Flow

```text
Source adapters
  BoardState + PlannerGraphState + transcript/session summaries + artifact refs
        |
        v
recap-core buildRecapInput()
        |
        v
fingerprint(input) -----> cache lookup
        |                     |
        | miss                | hit
        v                     v
buildCanvasRecap(input)   cached CanvasRecap
        |
        v
optional RecapGenerator.generate(prompt)
        |
        v
merge deterministic + AI wording
        |
        v
persist cache + render
```

The deterministic recap path must succeed without network, API keys, or a local
agent runtime.

## Core Contracts

### `SessionRecap`

```ts
export interface SessionRecap {
  scope: 'session'
  sessionId: string
  provider: string
  headline: string
  details: string[]
  statusSignals: RecapStatusSignal[]
  evidenceRefs: EvidenceRef[]
  source: RecapSource
  updatedAt: string
  fingerprint: string
}
```

`SessionRecap` is the normalized cross-provider shape. Claude `away_summary`,
Codex transcript summaries, user notes, and future provider summaries should all
adapt into this shape.

### `CanvasRecap`

```ts
export interface CanvasRecap {
  scope: 'canvas'
  canvasId: string
  headline: string
  details: string[]
  statusCounts: RecapStatusCount[]
  blockers: RecapBlocker[]
  approvals: RecapApproval[]
  evidenceRefs: EvidenceRef[]
  sessionRefs: string[]
  subCanvasRefs: string[]
  source: RecapSource
  updatedAt: string
  fingerprint: string
  stale: boolean
}
```

`CanvasRecap` is the object UI surfaces should render. It should be useful even
when `source.kind === 'deterministic'`.

### Shared Types

```ts
export type RecapStatusTone =
  | 'ready'
  | 'running'
  | 'attention'
  | 'approval'
  | 'done'
  | 'failed'
  | 'neutral'

export interface RecapStatusCount {
  label: string
  value: number
  tone: RecapStatusTone
}

export interface RecapStatusSignal {
  kind: 'active' | 'idle' | 'blocked' | 'needs_approval' | 'failed' | 'done' | 'unknown'
  label: string
  reason?: string
  subjectId?: string
}

export interface RecapBlocker {
  subjectId: string
  subjectKind: 'session' | 'node' | 'canvas' | 'artifact'
  title: string
  reason: string
  evidenceRefs: EvidenceRef[]
}

export interface RecapApproval {
  subjectId: string
  subjectKind: 'session' | 'node' | 'proposal' | 'gate'
  title: string
  requestedBy?: string
  requiredFrom?: string[]
  evidenceRefs: EvidenceRef[]
}

export interface EvidenceRef {
  id: string
  kind: 'transcript' | 'artifact' | 'diff' | 'file' | 'command' | 'pr' | 'tool_call' | 'event' | 'note'
  title: string
  reference: string
  createdAt?: string
  nodeId?: string
  sessionId?: string
}

export interface RecapSource {
  kind: 'deterministic' | 'ai' | 'provider' | 'mixed'
  provider?: string
  model?: string
  generatedFrom?: string[]
  error?: string
}
```

## Input Contracts

`recap-core` should consume a narrow, stable projection instead of importing the
entire app DTO graph.

```ts
export interface RecapInput {
  now: string
  canvas: RecapCanvasInput
  nodes: RecapNodeInput[]
  sessions: RecapSessionInput[]
  artifacts: EvidenceRef[]
  events: RecapEventInput[]
  proposals: RecapProposalInput[]
  subCanvases: RecapSubCanvasInput[]
  template?: RecapTemplatePolicy
}
```

The app can build this projection from `BoardState`, `PlannerGraphState`, and
adapter-provided transcript summaries. This keeps recap-core independent of
Swift and current DTO churn.

## Template Policy

Template policy controls prioritization, not hardcoded UI.

```ts
export interface RecapTemplatePolicy {
  id: string
  label: string
  statusStrategy: 'monitor' | 'workflow' | 'kanban' | 'dependency' | 'inbox'
  doneRequiresEvidence: boolean
  surfaceApprovals: boolean
  surfaceBlocked: boolean
  surfaceSubCanvasRollups: boolean
  maxSessionRecaps: number
  maxEvidenceRefs: number
}
```

Default policy:

- Show approvals before blockers.
- Show blockers before running work.
- Show evidence for done nodes.
- Roll subcanvas attention up to the parent canvas.
- Do not require `done` for monitor/inbox templates.
- Require evidence for workflow `done` claims.

## Cache Contract

`recap-core` defines the cache interface, but does not choose storage.

```ts
export interface RecapCache {
  get(key: string): Promise<CachedRecap | null>
  set(key: string, recap: CanvasRecap | SessionRecap): Promise<void>
  invalidate(scope: 'canvas' | 'session', id: string): Promise<void>
}

export interface CachedRecap {
  recap: CanvasRecap | SessionRecap
  storedAt: string
}
```

Cache key:

```text
recap:v1:<scope>:<id>:<fingerprint>
```

The fingerprint should include stable semantic inputs, not render-only fields:

- canvas id, title, context, template policy id
- node ids, titles, statuses, workflow run states, blocked reasons, gates
- session ids, statuses, current tasks, latest session recap fingerprints
- artifact ids, kind, status, title, createdAt
- proposal ids and statuses
- relevant event ids and timestamps
- subcanvas recap fingerprints

Manual refresh may bypass cache for AI generation, but should still write the
new result under the current fingerprint.

## AI Generation Contract

`recap-core` can build prompts and parse results, but model execution is injected.

```ts
export interface RecapGenerator {
  generate(input: RecapGenerationInput): Promise<RecapGenerationResult>
}

export interface RecapGenerationInput {
  prompt: string
  canvasId?: string
  workspacePath?: string
  locale: 'zh-CN' | 'en-US'
  maxDetails: number
}

export interface RecapGenerationResult {
  headline: string
  details: string[]
  model?: string
  raw?: string
}
```

Rules:

- AI output can replace `headline` and `details` only.
- AI output must not create blockers, approvals, or evidence refs that were not
  present in deterministic input.
- Parse failures fall back to deterministic recap.
- Model failures preserve deterministic recap and set `source.error`.

## API Shape

First cross-platform implementation can be app-side only, but the eventual HTTP
shape should be storage/runtime agnostic:

| Endpoint | Purpose |
|---|---|
| `GET /api/recap/canvases/:id` | Return cached or deterministic canvas recap for current source state. |
| `POST /api/recap/canvases/:id/refresh` | Recompute recap; optional AI generation; persist cache. |
| `GET /api/recap/sessions/:id` | Return normalized session recap. |
| `POST /api/recap/cache/invalidate` | Invalidate by scope/id after source mutation. |

The endpoint implementation may be Swift for local board serving, Node for cloud,
or browser-only for the first board-app spike. The contract stays TypeScript.

## Migration Plan

### Phase 1: Extract Pure Recap Logic

- Move `CanvasToolbar` recap types and pure functions into recap-core:
  - status count building
  - prompt building
  - AI JSON parsing
  - age formatting if kept framework-free
- Keep existing UI behavior.
- Add unit tests for deterministic recap and parser fallback.

### Phase 2: Better Input Projection

- Build `RecapInput` from `BoardState + PlannerGraphState`.
- Include session `latestRecap`, pending permission, current task, and recent
  message snippets where available.
- Preserve deterministic status counts when AI fails.

### Phase 3: Portable Cache

- Add `RecapCache` adapter in board-app.
- Use fingerprint cache keys instead of `useRef<Record<canvasId, recap>>`.
- Keep manual refresh and interval refresh semantics.

### Phase 4: Session Recap Normalization

- Normalize current Claude `away_summary` into `SessionRecap`.
- Add provider adapter slots for Codex and future providers.
- Stop treating session recap as only `latestRecap.content`.

### Phase 5: HTTP/Online Ready

- Add HTTP endpoints only after recap-core is stable.
- Reuse the same recap-core in local board and online service.
- Add export/snapshot support so team-ready recap can be shared without raw
  transcript access.

## Acceptance Signals

- A canvas with no AI settings still shows useful deterministic recap.
- A canvas refresh that fails model generation keeps status counts and evidence.
- Switching between canvases does not regenerate unchanged recaps.
- A completed workflow recap names evidence refs for completed nodes.
- A permission-blocked session surfaces as an approval/attention item in canvas
  recap.
- A subcanvas with blockers rolls up to parent canvas recap.
- Unit tests cover parser fallback, fingerprint stability, blocker extraction,
  approval extraction, and evidence-linked done nodes.

## Open Questions

1. Should the first package be `packages/recap-core` or a `board-core/src/recap`
   namespace that can be split later?
2. Should cache persistence be localStorage first, IndexedDB first, or HTTP first?
3. Should AI recap default locale follow UI locale or workspace/team preference?
4. What is the minimum session recap source for Codex in v0.1?
5. Which template policies must ship for internal dogfood: monitor, workflow,
   kanban, inbox/list?

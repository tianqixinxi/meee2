// Convenience re-exports so consumers can `import { LayoutMap, ... } from '@meee1/board-core'`.

export type { Point, LayoutMap } from './layout'
export type {
  ChannelMode,
  ChannelForScene,
  SessionForScene,
  BoardStateForScene,
  SkeletonElement,
} from './scene'
export type { PersistedViewport, CanvasPersistence } from './persistence'
export type {
  SessionForInspector,
  UsageStatsForInspector,
  BackgroundAgentForInspector,
  SessionRecapForInspector,
  InboxItemForInspector,
  ChannelMembershipForInspector,
} from './inspector'
export type {
  TranscriptBlockType,
  TranscriptBlockForView,
  TranscriptEntryRole,
  TranscriptEntryForView,
} from './transcript'

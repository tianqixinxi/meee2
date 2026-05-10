// Structural types consumed by @meee1/board-ui's <TranscriptView>.
//
// Mirrors meee2's `FullTranscriptEntry` / `FullTranscriptBlock` from the
// Swift backend, since that is the richer of the two app schemas. meee2
// derives entries from `meee2_transcript_messages` rows by mapping the
// stored `content` JSON (which can be raw `{text}` or full block array)
// into this shape.

export type TranscriptBlockType =
  | 'text'
  | 'thinking'
  | 'tool_use'
  | 'tool_result'

export interface TranscriptBlockForView {
  type: TranscriptBlockType
  text?: string
  toolId?: string
  toolName?: string
  toolInputJSON?: string
  toolUseId?: string
  toolResultText?: string
  toolResultTruncated?: boolean
}

export type TranscriptEntryRole = 'user' | 'assistant' | 'system' | 'injected'

export interface TranscriptEntryForView {
  id: string
  type: TranscriptEntryRole
  timestamp: string | null
  blocks: TranscriptBlockForView[]
}

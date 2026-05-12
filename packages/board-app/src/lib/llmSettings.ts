// LLM provider settings for the global assistant chatbox. Mirrors meee2's
// `llm-settings.ts` shape (apiKey + baseUrl + model in localStorage), plus
// a `provider` discriminator and a per-tool enable map specific to meee2.
//
// Defaults are tuned so the assistant works *out of the box* with no key:
// `provider: 'local'` shells out to `claude -p` using the user's existing
// `~/.claude/` OAuth, and all tools are enabled. Setting an `apiKey` and
// switching `provider` to `openai` / `anthropic` swaps in a hosted LLM.

export type LlmProvider = 'openai' | 'anthropic' | 'local'

export type ToolName =
  | 'get_canvas_context'
  | 'get_session_list'
  | 'get_session_info'
  | 'get_session_transcript'
  | 'propose_canvas_patch'
  | 'create_session'
  | 'create_coordinator_session'
  | 'get_coordination_state'
  | 'update_group_digest'
  | 'pause_coordination'
  | 'resume_coordination'
  | 'ask_coordinator'

export const ALL_TOOLS: ToolName[] = [
  'get_canvas_context',
  'get_session_list',
  'get_session_info',
  'get_session_transcript',
  'propose_canvas_patch',
  'create_session',
  'create_coordinator_session',
  'get_coordination_state',
  'update_group_digest',
  'pause_coordination',
  'resume_coordination',
  'ask_coordinator',
]

export interface LlmSettings {
  provider: LlmProvider
  /** Required for openai / anthropic. Ignored for local. */
  apiKey: string
  /** Override for hosted endpoints. Empty = provider default. */
  baseUrl: string
  /** Empty = provider default (gpt-4o-mini, claude-haiku-4-5, claude -p's CLI default). */
  model: string
  /** Per-tool enable flag. Default: all true. */
  enabledTools: Record<ToolName, boolean>
}

export const LLM_SETTINGS_STORAGE_KEY = 'meee2.llmSettings'

/** Default endpoint per provider — applied when `baseUrl` is empty. */
export const DEFAULT_BASE_URL: Record<LlmProvider, string> = {
  openai: 'https://api.openai.com/v1',
  anthropic: 'https://api.anthropic.com',
  local: '',
}

export const DEFAULT_MODEL: Record<LlmProvider, string> = {
  openai: 'gpt-4o-mini',
  anthropic: 'claude-haiku-4-5-20251001',
  local: '',
}

export const DEFAULT_LLM_SETTINGS: LlmSettings = {
  provider: 'local',
  apiKey: '',
  baseUrl: '',
  model: '',
  enabledTools: {
    get_canvas_context: true,
    get_session_list: true,
    get_session_info: true,
    get_session_transcript: true,
    propose_canvas_patch: true,
    create_session: true,
    create_coordinator_session: true,
    get_coordination_state: true,
    update_group_digest: true,
    pause_coordination: true,
    resume_coordination: true,
    ask_coordinator: true,
  },
}

export function readLlmSettings(): LlmSettings {
  if (typeof window === 'undefined') return DEFAULT_LLM_SETTINGS
  const raw = window.localStorage.getItem(LLM_SETTINGS_STORAGE_KEY)
  if (!raw) return DEFAULT_LLM_SETTINGS
  try {
    const parsed = JSON.parse(raw) as Partial<LlmSettings>
    const provider: LlmProvider =
      parsed.provider === 'openai' || parsed.provider === 'anthropic' || parsed.provider === 'local'
        ? parsed.provider
        : 'local'
    const enabledTools = { ...DEFAULT_LLM_SETTINGS.enabledTools }
    if (parsed.enabledTools && typeof parsed.enabledTools === 'object') {
      for (const k of ALL_TOOLS) {
        const v = (parsed.enabledTools as Record<string, unknown>)[k]
        if (typeof v === 'boolean') enabledTools[k] = v
      }
    }
    return {
      provider,
      apiKey: typeof parsed.apiKey === 'string' ? parsed.apiKey : '',
      baseUrl: typeof parsed.baseUrl === 'string' ? parsed.baseUrl : '',
      model: typeof parsed.model === 'string' ? parsed.model : '',
      enabledTools,
    }
  } catch {
    return DEFAULT_LLM_SETTINGS
  }
}

export function writeLlmSettings(settings: LlmSettings): void {
  window.localStorage.setItem(LLM_SETTINGS_STORAGE_KEY, JSON.stringify(settings))
  window.dispatchEvent(new Event('meee2:llm-settings-changed'))
}

/** Active list of enabled tool names — used to populate `enabledTools` on
 *  the chat request body. */
export function activeTools(settings: LlmSettings): ToolName[] {
  return ALL_TOOLS.filter((t) => settings.enabledTools[t])
}

/** Friendly label for the provider, shown in the UI. */
export function providerLabel(p: LlmProvider): string {
  switch (p) {
    case 'openai': return 'OpenAI-compatible'
    case 'anthropic': return 'Anthropic'
    case 'local': return 'Local (claude -p)'
  }
}

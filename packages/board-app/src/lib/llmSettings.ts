// LLM provider settings for the global assistant chatbox. Mirrors meee2's
// `llm-settings.ts` shape (apiKey + baseUrl + model in localStorage), plus
// a `provider` discriminator and a per-tool enable map specific to meee2.
//
// Defaults are tuned so the assistant works *out of the box* with no key:
// `provider: 'local'` shells out to `claude -p` using the user's existing
// `~/.claude/` OAuth with a stable local session. `provider: 'localCodex'`
// shells out to `codex exec --json` using the user's existing Codex login.
// Setting an `apiKey` and switching to `openai` / `anthropic` swaps in a hosted LLM.

export type LlmProvider = 'openai' | 'anthropic' | 'local' | 'localCodex'

export type ToolName =
  | 'get_canvas_context'
  | 'get_session_list'
  | 'get_session_info'
  | 'get_session_transcript'
  | 'list_channels'
  | 'get_channel_messages'
  | 'propose_canvas_patch'
  | 'create_session'
  | 'create_coordinator_session'
  | 'get_coordination_state'
  | 'send_to_session'
  | 'broadcast_to_members'
  | 'update_group_digest'
  | 'pause_coordination'
  | 'resume_coordination'
  | 'ask_coordinator'

export const ALL_TOOLS: ToolName[] = [
  'get_canvas_context',
  'get_session_list',
  'get_session_info',
  'get_session_transcript',
  'list_channels',
  'get_channel_messages',
  'propose_canvas_patch',
  'create_session',
  'create_coordinator_session',
  'get_coordination_state',
  'send_to_session',
  'broadcast_to_members',
  'update_group_digest',
  'pause_coordination',
  'resume_coordination',
  'ask_coordinator',
]

export interface LlmSettings {
  provider: LlmProvider
  /** Required for openai / anthropic. Ignored for local CLI providers. */
  apiKey: string
  /** Override for hosted endpoints. Empty = provider default. */
  baseUrl: string
  /** Empty = provider default (gpt-4o-mini, claude-haiku-4-5, local CLI default). */
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
  localCodex: '',
}

export const DEFAULT_MODEL: Record<LlmProvider, string> = {
  openai: 'gpt-4o-mini',
  anthropic: 'claude-haiku-4-5-20251001',
  local: '',
  localCodex: '',
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
    list_channels: true,
    get_channel_messages: true,
    propose_canvas_patch: true,
    create_session: true,
    create_coordinator_session: true,
    get_coordination_state: true,
    send_to_session: true,
    broadcast_to_members: true,
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
      parsed.provider === 'openai'
        || parsed.provider === 'anthropic'
        || parsed.provider === 'local'
        || parsed.provider === 'localCodex'
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
  // Hosted credentials live in macOS Keychain via /api/assistant/secret.
  // Never mirror them back into browser storage after the legacy migration.
  const persisted = {
    provider: settings.provider,
    baseUrl: settings.baseUrl,
    model: settings.model,
    enabledTools: settings.enabledTools,
  }
  window.localStorage.setItem(LLM_SETTINGS_STORAGE_KEY, JSON.stringify(persisted))
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
    case 'local': return 'Local Claude session'
    case 'localCodex': return 'Local Codex session'
  }
}

export function isHostedLlmProvider(p: LlmProvider): p is 'openai' | 'anthropic' {
  return p === 'openai' || p === 'anthropic'
}

import { beforeEach, describe, expect, it } from 'vitest'
import {
  DEFAULT_LLM_SETTINGS,
  LLM_SETTINGS_STORAGE_KEY,
  readLlmSettings,
  writeLlmSettings,
} from './llmSettings'

describe('llmSettings credential persistence', () => {
  beforeEach(() => window.localStorage.clear())

  it('can read a legacy key once but never writes it back to localStorage', () => {
    window.localStorage.setItem(LLM_SETTINGS_STORAGE_KEY, JSON.stringify({
      ...DEFAULT_LLM_SETTINGS,
      provider: 'openai',
      apiKey: 'legacy-secret',
    }))

    const legacy = readLlmSettings()
    expect(legacy.apiKey).toBe('legacy-secret')

    writeLlmSettings(legacy)
    const persisted = window.localStorage.getItem(LLM_SETTINGS_STORAGE_KEY) ?? ''
    expect(persisted).not.toContain('legacy-secret')
    expect(JSON.parse(persisted)).not.toHaveProperty('apiKey')
  })
})

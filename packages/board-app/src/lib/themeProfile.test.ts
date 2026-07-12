import { afterEach, describe, expect, it } from 'vitest'
import {
  DEFAULT_THEME_PROFILE,
  activeThemeBranch,
  applyThemeProfile,
  normalizeThemeProfile,
  parseThemeProfile,
  presetThemeProfile,
  serializeThemeProfile,
} from './themeProfile'

describe('themeProfile', () => {
  afterEach(() => {
    document.documentElement.removeAttribute('style')
  })

  it('normalizes missing or invalid profiles to the Codex preset', () => {
    expect(normalizeThemeProfile(null)).toEqual(DEFAULT_THEME_PROFILE)
    expect(DEFAULT_THEME_PROFILE.presetId).toBe('codex')
    expect(parseThemeProfile({ schemaVersion: 2 })).toBeNull()
    expect(parseThemeProfile({
      ...DEFAULT_THEME_PROFILE,
      light: { ...DEFAULT_THEME_PROFILE.light, accentColor: 'blue' },
    })).toBeNull()
  })

  it('returns independent preset copies', () => {
    const codex = presetThemeProfile('codex')
    codex.light.accentColor = '#000000'

    expect(presetThemeProfile('codex').light.accentColor).toBe('#339CFF')
  })

  it('round-trips imported JSON', () => {
    const serialized = serializeThemeProfile(presetThemeProfile('codex'))
    const parsed = parseThemeProfile(JSON.parse(serialized))
    const exported = JSON.parse(serialized)

    expect(parsed?.presetId).toBe('codex')
    expect(parsed?.light.backgroundColor).toBe('#FFFFFF')
    expect(parsed?.light.sidebarColor).toBe('#FFFFFF')
    expect(parsed?.dark.contrast).toBe(62)
    expect(exported.light.uiFont).toBeUndefined()
    expect(exported.light.translucentSidebar).toBeUndefined()
  })

  it('keeps preset selection independent from custom branches', () => {
    const profile = {
      ...presetThemeProfile('claude'),
      presetId: 'codex' as const,
      light: {
        accentColor: '#112233',
        backgroundColor: '#FFFFFF',
        sidebarColor: '#F7F7F7',
        foregroundColor: '#000000',
        contrast: 50,
      },
    }

    expect(activeThemeBranch(profile, 'light').accentColor).toBe('#339CFF')
    expect({ ...profile, presetId: 'custom' as const }.light.accentColor).toBe('#112233')
  })

  it('applies light and dark branches as CSS variables', () => {
    const profile = presetThemeProfile('codex')

    applyThemeProfile(profile, 'light')
    expect(document.documentElement.style.getPropertyValue('--accent')).toBe('#339CFF')
    expect(document.documentElement.style.getPropertyValue('--bg')).toBe('#FFFFFF')
    expect(document.documentElement.style.getPropertyValue('--sidebar-bg')).toBe('#FFFFFF')
    expect(document.documentElement.style.getPropertyValue('--rail-accent')).toBe('#339CFF')
    expect(document.documentElement.style.getPropertyValue('--bg-rail-gradient')).toContain('rgba')

    applyThemeProfile(profile, 'dark')
    expect(document.documentElement.style.getPropertyValue('--accent')).toBe('#4DA6FF')
    expect(document.documentElement.style.getPropertyValue('--bg')).toBe('#101214')
    expect(document.documentElement.style.getPropertyValue('--sidebar-bg')).toBe('#171B20')
    expect(document.documentElement.style.getPropertyValue('--rail-accent')).toBe('#4DA6FF')
  })

  it('accepts older v1 imports without a sidebar color', () => {
    const parsed = parseThemeProfile({
      schemaVersion: 1,
      presetId: 'custom',
      light: {
        accentColor: '#112233',
        backgroundColor: '#FFFFFF',
        foregroundColor: '#000000',
        contrast: 50,
      },
      dark: {
        accentColor: '#445566',
        backgroundColor: '#101010',
        foregroundColor: '#FFFFFF',
        contrast: 50,
      },
    })

    expect(parsed?.light.sidebarColor).toBe('#FFFFFF')
    expect(parsed?.dark.sidebarColor).toBe('#101010')
  })
})

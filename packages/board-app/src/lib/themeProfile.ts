export type ThemePresetId = 'claude' | 'codex' | 'custom'

export interface ThemeBranch {
  accentColor: string
  backgroundColor: string
  sidebarColor: string
  foregroundColor: string
  contrast: number
}

export interface ThemeProfile {
  schemaVersion: 1
  presetId: ThemePresetId
  light: ThemeBranch
  dark: ThemeBranch
}

export const THEME_PRESETS: Record<Exclude<ThemePresetId, 'custom'>, ThemeProfile> = {
  claude: {
    schemaVersion: 1,
    presetId: 'claude',
    light: {
      accentColor: '#B95F43',
      backgroundColor: '#F4F1EA',
      sidebarColor: '#FBF8F1',
      foregroundColor: '#25211D',
      contrast: 55,
    },
    dark: {
      accentColor: '#CC785C',
      backgroundColor: '#262624',
      sidebarColor: '#2C2B29',
      foregroundColor: '#F5F4EF',
      contrast: 58,
    },
  },
  codex: {
    schemaVersion: 1,
    presetId: 'codex',
    light: {
      accentColor: '#339CFF',
      backgroundColor: '#FFFFFF',
      sidebarColor: '#F3F6FA',
      foregroundColor: '#1A1C1F',
      contrast: 45,
    },
    dark: {
      accentColor: '#4DA6FF',
      backgroundColor: '#101214',
      sidebarColor: '#171B20',
      foregroundColor: '#F4F7FB',
      contrast: 62,
    },
  },
}

export const DEFAULT_THEME_PROFILE: ThemeProfile = THEME_PRESETS.claude

const HEX_RE = /^#[0-9a-f]{6}$/i
const PRESET_IDS = new Set<ThemePresetId>(['claude', 'codex', 'custom'])

export function cloneThemeProfile(profile: ThemeProfile): ThemeProfile {
  return {
    schemaVersion: 1,
    presetId: profile.presetId,
    light: { ...profile.light },
    dark: { ...profile.dark },
  }
}

export function presetThemeProfile(presetId: Exclude<ThemePresetId, 'custom'>): ThemeProfile {
  return cloneThemeProfile(THEME_PRESETS[presetId])
}

export function activeThemeBranch(profile: ThemeProfile, resolvedTheme: 'light' | 'dark'): ThemeBranch {
  if (profile.presetId === 'claude' || profile.presetId === 'codex') {
    return THEME_PRESETS[profile.presetId][resolvedTheme]
  }
  return profile[resolvedTheme]
}

export function normalizeThemeProfile(value: unknown): ThemeProfile {
  return parseThemeProfile(value) ?? cloneThemeProfile(DEFAULT_THEME_PROFILE)
}

export function parseThemeProfile(value: unknown): ThemeProfile | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as Partial<ThemeProfile>
  if (raw.schemaVersion !== 1) return null
  if (!raw.presetId || !PRESET_IDS.has(raw.presetId)) return null
  const light = parseBranch(raw.light)
  const dark = parseBranch(raw.dark)
  if (!light || !dark) return null
  return {
    schemaVersion: 1,
    presetId: raw.presetId,
    light,
    dark,
  }
}

export function serializeThemeProfile(profile: ThemeProfile): string {
  return JSON.stringify(profile, null, 2)
}

export function applyThemeProfile(profile: ThemeProfile, resolvedTheme: 'light' | 'dark') {
  if (typeof document === 'undefined') return
  const branch = activeThemeBranch(profile, resolvedTheme)
  const root = document.documentElement
  const style = root.style
  const bg = branch.backgroundColor
  const sidebar = branch.sidebarColor
  const fg = branch.foregroundColor
  const accent = branch.accentColor
  const contrast = clamp(branch.contrast, 0, 100) / 100
  const isLight = relativeLuminance(bg) > relativeLuminance(fg)
  const elevatedRatio = isLight ? 0.04 + contrast * 0.05 : 0.10 + contrast * 0.08
  const paperRatio = isLight ? 0.02 + contrast * 0.035 : 0.06 + contrast * 0.06
  const dimRatio = 0.46 + contrast * 0.18
  const faintRatio = 0.26 + contrast * 0.12
  const borderRatio = isLight ? 0.18 + contrast * 0.14 : 0.18 + contrast * 0.10
  const railTop = mixHex(mixHex(bg, fg, elevatedRatio), accent, isLight ? 0.10 : 0.16)
  const railBottom = mixHex(bg, accent, isLight ? 0.06 : 0.11)

  style.setProperty('--bg', bg)
  style.setProperty('--sidebar-bg', sidebar)
  style.setProperty('--text', fg)
  style.setProperty('--accent', accent)
  style.setProperty('--accent-hover', mixHex(accent, fg, isLight ? 0.18 : 0.24))
  style.setProperty('--accent-subtle', alphaHex(accent, isLight ? 0.13 : 0.16))
  style.setProperty('--rail-accent', accent)
  style.setProperty('--rail-accent-hover', mixHex(accent, fg, isLight ? 0.16 : 0.24))
  style.setProperty('--rail-accent-subtle', alphaHex(accent, isLight ? 0.12 : 0.18))
  style.setProperty('--rail-active-bg', alphaHex(accent, isLight ? 0.14 : 0.18))
  style.setProperty('--rail-active-border', alphaHex(accent, isLight ? 0.24 : 0.30))
  style.setProperty('--rail-focus-ring', alphaHex(accent, isLight ? 0.22 : 0.28))
  style.setProperty('--bg-elevated', mixHex(bg, fg, elevatedRatio))
  style.setProperty('--bg-elevated-2', mixHex(bg, fg, elevatedRatio * 1.65))
  style.setProperty('--bg-paper', sidebar)
  style.setProperty('--surface', mixHex(bg, fg, elevatedRatio * 1.1))
  style.setProperty('--input-bg', mixHex(bg, fg, isLight ? paperRatio * 0.55 : paperRatio * 0.85))
  style.setProperty('--input-bg-focus', mixHex(bg, fg, isLight ? paperRatio * 0.25 : paperRatio * 1.2))
  style.setProperty('--modal-bg', mixHex(bg, fg, elevatedRatio))
  style.setProperty('--panel-bg', alphaHex(mixHex(bg, fg, paperRatio), isLight ? 0.9 : 0.78))
  style.setProperty('--panel-bg-hover', alphaHex(accent, isLight ? 0.08 : 0.07))
  style.setProperty('--text-dim', mixHex(bg, fg, dimRatio))
  style.setProperty('--text-faint', mixHex(bg, fg, faintRatio))
  style.setProperty('--border', mixHex(bg, fg, borderRatio))
  style.setProperty('--border-strong', mixHex(bg, fg, borderRatio * 1.45))
  style.setProperty('--scrollbar-thumb', alphaHex(mixHex(bg, fg, dimRatio), isLight ? 0.36 : 0.42))
  style.setProperty('--scrollbar-thumb-hover', alphaHex(mixHex(bg, fg, dimRatio + 0.16), isLight ? 0.54 : 0.55))
  style.setProperty('--bg-app-gradient', `linear-gradient(145deg, ${alphaHex(mixHex(bg, fg, paperRatio), 0.98)}, ${bg}), ${bg}`)
  style.setProperty('--bg-rail-gradient', `linear-gradient(180deg, ${alphaHex(railTop, 0.96)}, ${alphaHex(railBottom, 0.96)}), ${bg}`)
}

function parseBranch(value: unknown): ThemeBranch | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as Partial<ThemeBranch>
  if (!isHex(raw.accentColor) || !isHex(raw.backgroundColor) || !isHex(raw.foregroundColor)) return null
  const sidebarColor = isHex(raw.sidebarColor) ? raw.sidebarColor : raw.backgroundColor
  if (typeof raw.contrast !== 'number' || !Number.isFinite(raw.contrast)) return null
  return {
    accentColor: raw.accentColor.toUpperCase(),
    backgroundColor: raw.backgroundColor.toUpperCase(),
    sidebarColor: sidebarColor.toUpperCase(),
    foregroundColor: raw.foregroundColor.toUpperCase(),
    contrast: Math.round(clamp(raw.contrast, 0, 100)),
  }
}

function isHex(value: unknown): value is string {
  return typeof value === 'string' && HEX_RE.test(value)
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value))
}

function hexToRgb(hex: string): [number, number, number] {
  const normalized = hex.replace('#', '')
  return [
    Number.parseInt(normalized.slice(0, 2), 16),
    Number.parseInt(normalized.slice(2, 4), 16),
    Number.parseInt(normalized.slice(4, 6), 16),
  ]
}

function rgbToHex([r, g, b]: [number, number, number]) {
  return `#${[r, g, b].map((part) => Math.round(clamp(part, 0, 255)).toString(16).padStart(2, '0')).join('')}`
}

function mixHex(left: string, right: string, ratio: number) {
  const l = hexToRgb(left)
  const r = hexToRgb(right)
  const amount = clamp(ratio, 0, 1)
  return rgbToHex([
    l[0] + (r[0] - l[0]) * amount,
    l[1] + (r[1] - l[1]) * amount,
    l[2] + (r[2] - l[2]) * amount,
  ])
}

function alphaHex(hex: string, alpha: number) {
  const [r, g, b] = hexToRgb(hex)
  return `rgba(${r}, ${g}, ${b}, ${clamp(alpha, 0, 1).toFixed(3)})`
}

function relativeLuminance(hex: string) {
  const [r, g, b] = hexToRgb(hex).map((channel) => {
    const value = channel / 255
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

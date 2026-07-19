import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { fetchAppSettings } from '../api'
import {
  DEFAULT_THEME_PROFILE,
  applyThemeProfile,
  cloneThemeProfile,
  normalizeThemeProfile,
  type ThemeProfile,
} from './themeProfile'

export type ThemeMode = 'system' | 'light' | 'dark'
export type ResolvedTheme = 'light' | 'dark'

interface ThemeContextValue {
  mode: ThemeMode
  resolvedTheme: ResolvedTheme
  themeProfile: ThemeProfile
  setMode: (mode: ThemeMode) => void
  setThemeProfile: (profile: ThemeProfile) => void
}

const STORAGE_KEY = 'meee2.theme'
const ThemeContext = createContext<ThemeContextValue | null>(null)

function isThemeMode(value: unknown): value is ThemeMode {
  return value === 'system' || value === 'light' || value === 'dark'
}

function systemTheme(): ResolvedTheme {
  if (typeof window === 'undefined') return 'dark'
  return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'
}

function readStoredMode(): ThemeMode {
  if (typeof window === 'undefined') return 'system'
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY)
    return isThemeMode(stored) ? stored : 'system'
  } catch {
    return 'system'
  }
}

function applyTheme(theme: ResolvedTheme) {
  if (typeof document === 'undefined') return
  // 切换瞬间全站禁 transition 两帧：否则各元素以各自时长渐变，
  // 主题切换看起来像"颜色爬行"（借 orca document-theme.ts 的做法）。
  const root = document.documentElement
  root.classList.add('theme-transition-disabled')
  root.dataset.theme = theme
  root.style.colorScheme = theme
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      root.classList.remove('theme-transition-disabled')
    })
  })
}

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const [mode, setModeState] = useState<ThemeMode>(() => readStoredMode())
  const [systemThemeValue, setSystemThemeValue] = useState<ResolvedTheme>(() => systemTheme())
  const [themeProfile, setThemeProfileState] = useState<ThemeProfile>(() => cloneThemeProfile(DEFAULT_THEME_PROFILE))
  const themeProfileDirtyRef = useRef(false)
  const resolvedTheme = mode === 'system' ? systemThemeValue : mode

  useEffect(() => {
    applyTheme(resolvedTheme)
    applyThemeProfile(themeProfile, resolvedTheme)
  }, [resolvedTheme, themeProfile])

  useEffect(() => {
    const query = window.matchMedia('(prefers-color-scheme: light)')
    const update = () => setSystemThemeValue(query.matches ? 'light' : 'dark')
    query.addEventListener('change', update)
    return () => query.removeEventListener('change', update)
  }, [])

  useEffect(() => {
    let cancelled = false
    fetchAppSettings()
      .then((settings) => {
        if (cancelled) return
        if (isThemeMode(settings.theme)) {
          try {
            window.localStorage.setItem(STORAGE_KEY, settings.theme)
          } catch {
            // Storage is an optimization; backend settings remain authoritative.
          }
          setModeState(settings.theme)
        }
        if (!themeProfileDirtyRef.current) {
          setThemeProfileState(normalizeThemeProfile(settings.themeProfile))
        }
      })
      .catch(() => {
        if (!cancelled && !themeProfileDirtyRef.current) setThemeProfileState(cloneThemeProfile(DEFAULT_THEME_PROFILE))
      })
    return () => {
      cancelled = true
    }
  }, [])

  const setMode = useCallback((nextMode: ThemeMode) => {
    try {
      window.localStorage.setItem(STORAGE_KEY, nextMode)
    } catch {
      // Theme should still update in WebViews where storage is unavailable.
    }
    setModeState(nextMode)
  }, [])

  const setThemeProfile = useCallback((profile: ThemeProfile) => {
    themeProfileDirtyRef.current = true
    setThemeProfileState(normalizeThemeProfile(profile))
  }, [])

  const value = useMemo(
    () => ({ mode, resolvedTheme, themeProfile, setMode, setThemeProfile }),
    [mode, resolvedTheme, themeProfile, setMode, setThemeProfile],
  )

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
}

export function useTheme(): ThemeContextValue {
  const value = useContext(ThemeContext)
  if (!value) throw new Error('useTheme must be used inside ThemeProvider')
  return value
}

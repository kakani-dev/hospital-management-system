// Ported from Tailux starter src/app/contexts/theme/Provider.jsx (typed, reduced to what HMS uses:
// light/dark/system mode and card skin; the palettes are fixed in configs/theme.config.ts).
// The preference lives in localStorage (a UI preference, not session data) and is applied before
// first paint by the inline script in index.html, so there is no light flash in dark mode.
import { useCallback, useLayoutEffect, useMemo, useState, type ReactNode } from 'react'
import { defaultTheme, THEME_STORAGE_KEY, type CardSkin, type ThemeMode } from '../../configs/theme.config'
import { ThemeContext } from './context'

const COLOR_SCHEME_QUERY = '(prefers-color-scheme: dark)'

interface StoredSettings {
  themeMode: ThemeMode
  cardSkin: CardSkin
}

function readSettings(): StoredSettings {
  const fallback: StoredSettings = { themeMode: defaultTheme.themeMode, cardSkin: defaultTheme.cardSkin }
  try {
    const raw = window.localStorage.getItem(THEME_STORAGE_KEY)
    if (!raw) return fallback
    const parsed = JSON.parse(raw) as Partial<StoredSettings>
    return {
      themeMode: parsed.themeMode === 'light' || parsed.themeMode === 'dark' || parsed.themeMode === 'system' ? parsed.themeMode : fallback.themeMode,
      cardSkin: parsed.cardSkin === 'shadow' || parsed.cardSkin === 'bordered' ? parsed.cardSkin : fallback.cardSkin,
    }
  } catch {
    return fallback
  }
}

function systemPrefersDark() {
  return typeof window.matchMedia === 'function' && window.matchMedia(COLOR_SCHEME_QUERY).matches
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [settings, setSettings] = useState<StoredSettings>(readSettings)
  const [isDarkOS, setIsDarkOS] = useState(systemPrefersDark)

  useLayoutEffect(() => {
    if (typeof window.matchMedia !== 'function') return
    const mql = window.matchMedia(COLOR_SCHEME_QUERY)
    const onChange = () => setIsDarkOS(mql.matches)
    mql.addEventListener('change', onChange)
    return () => mql.removeEventListener('change', onChange)
  }, [])

  const isDark = (settings.themeMode === 'system' && isDarkOS) || settings.themeMode === 'dark'

  const persist = useCallback((next: StoredSettings) => {
    setSettings(next)
    try {
      window.localStorage.setItem(THEME_STORAGE_KEY, JSON.stringify(next))
    } catch {
      /* storage unavailable: keep the in-memory preference */
    }
  }, [])

  const setThemeMode = useCallback((themeMode: ThemeMode) => persist({ ...settings, themeMode }), [persist, settings])
  const setCardSkin = useCallback((cardSkin: CardSkin) => persist({ ...settings, cardSkin }), [persist, settings])

  useLayoutEffect(() => {
    const html = document.documentElement
    html.classList.toggle('dark', isDark)
    html.style.colorScheme = isDark ? 'dark' : 'light'
  }, [isDark])

  useLayoutEffect(() => {
    const html = document.documentElement
    html.dataset.themeLight = defaultTheme.lightColorScheme
    html.dataset.themeDark = defaultTheme.darkColorScheme
    html.dataset.themePrimary = defaultTheme.primaryColorScheme
    html.dataset.cardSkin = settings.cardSkin
    document.body.dataset.layout = defaultTheme.themeLayout
  }, [settings.cardSkin])

  const value = useMemo(
    () => ({
      themeMode: settings.themeMode,
      cardSkin: settings.cardSkin,
      themeLayout: defaultTheme.themeLayout,
      notification: defaultTheme.notification,
      isDark,
      setThemeMode,
      setCardSkin,
    }),
    [settings, isDark, setThemeMode, setCardSkin],
  )

  return <ThemeContext value={value}>{children}</ThemeContext>
}

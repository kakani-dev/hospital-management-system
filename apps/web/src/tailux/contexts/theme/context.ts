import { createContext, useContext } from 'react'
import { defaultTheme, type CardSkin, type ThemeMode } from '../../configs/theme.config'

export interface ThemeContextValue {
  themeMode: ThemeMode
  isDark: boolean
  cardSkin: CardSkin
  themeLayout: 'sideblock'
  notification: (typeof defaultTheme)['notification']
  setThemeMode: (mode: ThemeMode) => void
  setCardSkin: (skin: CardSkin) => void
}

// Unlike the template's createSafeContext, components outside ThemeProvider (unit tests that render
// a single screen) get the default light theme instead of an error.
const fallback: ThemeContextValue = {
  themeMode: 'light',
  isDark: false,
  cardSkin: defaultTheme.cardSkin,
  themeLayout: defaultTheme.themeLayout,
  notification: defaultTheme.notification,
  setThemeMode: () => {},
  setCardSkin: () => {},
}

export const ThemeContext = createContext<ThemeContextValue>(fallback)
export const useThemeContext = () => useContext(ThemeContext)

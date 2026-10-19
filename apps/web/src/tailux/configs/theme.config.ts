// Ported from Tailux starter src/configs/theme.config.js. HMS uses the Sideblock layout only and
// keeps the template's default palettes; the customizer (layout/monochrome/scheme pickers) is not ported.
export type ThemeMode = 'light' | 'dark' | 'system'
export type CardSkin = 'bordered' | 'shadow'

export const THEME_STORAGE_KEY = 'hms.theme'

export const defaultTheme = {
  themeMode: 'system' as ThemeMode,
  themeLayout: 'sideblock' as const,
  cardSkin: 'bordered' as CardSkin,
  // Options in the template: "cinder", "navy", "mirage", "black", "mint"
  darkColorScheme: 'cinder',
  // Options: "slate", "gray", "neutral"
  lightColorScheme: 'slate',
  // Options: "indigo", "blue", "green", "amber", "purple", "rose"
  primaryColorScheme: 'blue',
  notification: {
    isExpanded: false,
    position: 'bottom-right' as const,
    visibleToasts: 4,
  },
}

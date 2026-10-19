import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider } from './Provider'
import { ThemeModeSwitch } from '../../components/shared/ThemeModeSwitch'
import { THEME_STORAGE_KEY } from '../../configs/theme.config'

afterEach(() => {
  localStorage.clear()
  document.documentElement.classList.remove('dark')
})

describe('ThemeProvider (Tailux theme modes)', () => {
  it('applies the saved dark mode to <html> and the template data attributes', () => {
    localStorage.setItem(THEME_STORAGE_KEY, JSON.stringify({ themeMode: 'dark', cardSkin: 'bordered' }))
    render(
      <ThemeProvider>
        <p>x</p>
      </ThemeProvider>,
    )
    const html = document.documentElement
    expect(html).toHaveClass('dark')
    expect(html.dataset.themePrimary).toBe('blue')
    expect(html.dataset.cardSkin).toBe('bordered')
    expect(document.body.dataset.layout).toBe('sideblock')
  })

  it('switches between light and dark from the theme switch and persists the choice', async () => {
    const user = userEvent.setup()
    render(
      <ThemeProvider>
        <ThemeModeSwitch />
      </ThemeProvider>,
    )
    // jsdom has no matchMedia: "system" resolves to light.
    expect(document.documentElement).not.toHaveClass('dark')
    await user.click(screen.getByRole('radio', { name: 'Dark theme' }))
    expect(document.documentElement).toHaveClass('dark')
    expect(JSON.parse(localStorage.getItem(THEME_STORAGE_KEY)!)).toMatchObject({ themeMode: 'dark' })
    await user.click(screen.getByRole('radio', { name: 'Light theme' }))
    expect(document.documentElement).not.toHaveClass('dark')
    expect(screen.getByRole('radio', { name: 'Light theme' })).toBeChecked()
  })
})
